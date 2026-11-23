import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../core/local_logger.dart';
import '../core/secret_store.dart';

const _keyName = 'local_database_key';

/// UUID em 16 bytes, como o SQLite guarda.
Uint8List uuidBytes(String value) => Uint8List.fromList(Uuid.parse(value));

/// UUID em texto, a partir dos 16 bytes do SQLite.
String uuidText(List<int> bytes) => Uuid.unparse(bytes);

/// Dinheiro em centavos: nada de ponto flutuante no caixa.
int? toCents(Object? value) =>
    value == null ? null : ((value as num) * 100).round();

/// Quantidade em milésimos (o banco central guarda três casas).
int? toMilli(Object? value) =>
    value == null ? null : ((value as num) * 1000).round();

/// Situação da descida, gravada junto com os dados.
class SyncState {
  const SyncState({
    this.cursor,
    this.windowUntil,
    this.windowAfter,
    this.windowTotal,
    this.windowReceived = 0,
    this.generation = 0,
    this.format,
    this.initialLoadDone = false,
    this.lastPullAt,
  });

  /// Até onde a cópia local está em dia. Vazio: falta a carga inicial.
  final String? cursor;

  /// Janela em andamento: retomada daqui se o PDV fechar no meio.
  final String? windowUntil;
  final String? windowAfter;
  final int? windowTotal;
  final int windowReceived;

  /// Cada carga inteira tem uma geração; o que não veio nela sai da cópia local.
  final int generation;
  final int? format;
  final bool initialLoadDone;
  final DateTime? lastPullAt;
}

/// Pacote recebido da central.
class PullPage {
  const PullPage({
    required this.format,
    required this.until,
    required this.items,
    this.total,
    this.next,
  });

  factory PullPage.fromJson(Map<String, dynamic> json) => PullPage(
    format: json['format'] as int,
    until: json['until'] as String,
    total: json['total'] as int?,
    next: json['next'] as String?,
    items: (json['items'] as List)
        .cast<Map<String, dynamic>>()
        .map(
          (item) => PullItem(
            type: item['type'] as String,
            id: item['id'] as String,
            data: item['data'] as Map<String, dynamic>?,
          ),
        )
        .toList(),
  );

  final int format;
  final String until;
  final int? total;
  final String? next;
  final List<PullItem> items;
}

class PullItem {
  const PullItem({required this.type, required this.id, this.data});

  final String type;
  final String id;

  /// Vazio: o item saiu do escopo da filial e deixa a cópia local.
  final Map<String, dynamic>? data;
}

/// Produto encontrado pela leitura do código de barras.
class LocalProduct {
  const LocalProduct({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.priceCents,
    required this.stockMilli,
  });

  final String id;
  final int code;
  final String name;
  final String status;
  final int? priceCents;
  final int stockMilli;
}

/// Migrações do banco local, em ordem. Só se acrescenta no fim: nunca se altera uma que já saiu.
const _migrations = <String>[
  '''
  CREATE TABLE sync_state (
    key TEXT PRIMARY KEY,
    value TEXT
  ) STRICT;

  CREATE TABLE fiscal (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    data TEXT NOT NULL,
    seen_generation INTEGER NOT NULL
  ) STRICT;

  -- O último número da central e o local ficam separados: a descida nunca volta a numeração.
  CREATE TABLE fiscal_series (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    model TEXT NOT NULL,
    series INTEGER NOT NULL,
    initial_number INTEGER NOT NULL,
    central_last_used_number INTEGER,
    local_last_used_number INTEGER,
    active INTEGER NOT NULL DEFAULT 1
  ) STRICT;

  CREATE TABLE app_user (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    code INTEGER NOT NULL,
    name TEXT NOT NULL,
    is_admin INTEGER NOT NULL,
    roles TEXT NOT NULL,
    permissions TEXT NOT NULL,
    limits TEXT NOT NULL,
    seen_generation INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX app_user_code_idx ON app_user (code);

  CREATE TABLE product (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    code INTEGER NOT NULL,
    name TEXT NOT NULL,
    manufacturer TEXT,
    active_ingredient TEXT,
    controlled_class TEXT,
    ms_registration TEXT,
    ncm TEXT,
    cest TEXT,
    status TEXT NOT NULL,
    price_cents INTEGER,
    fraction_milli INTEGER NOT NULL,
    batch_required INTEGER NOT NULL,
    seen_generation INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX product_code_idx ON product (code);

  CREATE TABLE product_barcode (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    product_id BLOB NOT NULL REFERENCES product (id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    is_primary INTEGER NOT NULL,
    fraction_milli INTEGER
  ) STRICT;
  CREATE INDEX product_barcode_code_idx ON product_barcode (code);
  CREATE INDEX product_barcode_product_idx ON product_barcode (product_id);

  -- Regra em vigor e as futuras; a venda escolhe pela data. A regra é do item do Catálogo:
  -- a mesma pode valer para dois produtos da cópia local, por isso a chave inclui o produto.
  CREATE TABLE product_tax (
    product_id BLOB NOT NULL REFERENCES product (id) ON DELETE CASCADE,
    id BLOB NOT NULL CHECK (length(id) = 16),
    valid_from TEXT NOT NULL,
    data TEXT NOT NULL,
    PRIMARY KEY (product_id, id)
  ) STRICT;

  CREATE TABLE stock (
    product_id BLOB PRIMARY KEY REFERENCES product (id) ON DELETE CASCADE,
    quantity_milli INTEGER NOT NULL
  ) STRICT;

  CREATE TABLE stock_batch (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    product_id BLOB NOT NULL REFERENCES product (id) ON DELETE CASCADE,
    number TEXT NOT NULL,
    expires_on TEXT NOT NULL,
    quantity_milli INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX stock_batch_product_idx ON stock_batch (product_id);
  ''',
];

/// Banco local do PDV: cópia enxuta da filial, criptografada no disco.
class LocalDatabase {
  LocalDatabase._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    _migrate();
  }

  final Database _db;

  /// Abre (ou cria) o banco criptografado. A chave nasce no aparelho e fica no cofre do sistema.
  ///
  /// Se o arquivo não abrir com a chave (cofre apagado, por exemplo), ele é guardado de lado
  /// com outro nome e o PDV começa uma cópia nova: os dados voltam pela carga inicial.
  static Future<LocalDatabase> open({
    required File file,
    required SecretStore store,
    LocalLogger? logger,
  }) async {
    final key = await _loadOrCreateKey(store);
    file.parent.createSync(recursive: true);
    try {
      return LocalDatabase._(_openEncrypted(file.path, key));
    } on SqliteException catch (error) {
      if (!file.existsSync()) rethrow;
      final aside = File(
        '${file.path}.ilegivel-${DateTime.now().millisecondsSinceEpoch}',
      );
      file.renameSync(aside.path);
      logger?.warn(
        'Banco local ilegível com a chave atual; começando uma cópia nova',
        fields: {'error_code': 'FA957', 'sqlite_code': error.extendedResultCode},
      );
      return LocalDatabase._(_openEncrypted(file.path, key));
    }
  }

  /// Banco em memória, para os testes.
  factory LocalDatabase.inMemory() => LocalDatabase._(sqlite3.openInMemory());

  static Database _openEncrypted(String path, String key) {
    final db = sqlite3.open(path);
    try {
      // A chave tem só dígitos hexadecimais: não há o que escapar.
      db.execute("PRAGMA key = '$key'");
      // Confere a chave agora: com a chave errada, a primeira leitura falha.
      db.select('SELECT count(*) FROM sqlite_master');
      db.execute('PRAGMA journal_mode = WAL');
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  static Future<String> _loadOrCreateKey(SecretStore store) async {
    final existing = await store.read(_keyName);
    if (existing != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(existing)) {
      return existing;
    }
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await store.write(_keyName, key);
    return key;
  }

  int get schemaVersion => _db.select('PRAGMA user_version').first.columnAt(0) as int;

  void _migrate() {
    final current = schemaVersion;
    for (var index = current; index < _migrations.length; index += 1) {
      _transaction(() {
        _db.execute(_migrations[index]);
        _db.execute('PRAGMA user_version = ${index + 1}');
      });
    }
  }

  void close() => _db.close();

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? _state(String key) {
    final rows = _db.select('SELECT value FROM sync_state WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void _setState(String key, Object? value) => _db.execute(
    'INSERT INTO sync_state (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value?.toString()],
  );

  SyncState get syncState => SyncState(
    cursor: _state('cursor'),
    windowUntil: _state('window_until'),
    windowAfter: _state('window_after'),
    windowTotal: int.tryParse(_state('window_total') ?? ''),
    windowReceived: int.tryParse(_state('window_received') ?? '') ?? 0,
    generation: int.tryParse(_state('generation') ?? '') ?? 0,
    format: int.tryParse(_state('format') ?? ''),
    initialLoadDone: _state('initial_load_done') == '1',
    lastPullAt: DateTime.tryParse(_state('last_pull_at') ?? ''),
  );

  /// Começa uma carga inteira: nova geração e janela vazia. Os dados atuais ficam até ela terminar.
  void startFullLoad() => _transaction(() {
    _setState('generation', syncState.generation + 1);
    _setState('cursor', null);
    _clearWindow();
  });

  void _clearWindow() {
    _setState('window_until', null);
    _setState('window_after', null);
    _setState('window_total', null);
    _setState('window_received', 0);
  }

  /// Aplica um pacote e avança a janela na mesma transação: se o PDV cair no meio,
  /// recomeça do último pacote gravado.
  void applyPage(PullPage page, {required DateTime now}) => _transaction(() {
    final state = syncState;
    final fullLoad = state.cursor == null;
    for (final item in page.items) {
      _applyItem(item, state.generation);
    }
    if (page.next != null) {
      _setState('window_until', page.until);
      _setState('window_after', page.next);
      if (page.total != null) _setState('window_total', page.total);
      _setState('window_received', state.windowReceived + page.items.length);
      return;
    }
    if (fullLoad) {
      // O que não veio na carga inteira saiu do escopo da filial.
      for (final table in ['product', 'app_user', 'fiscal']) {
        _db.execute('DELETE FROM $table WHERE seen_generation < ?', [state.generation]);
      }
      _setState('initial_load_done', 1);
    }
    _setState('cursor', page.until);
    _setState('format', page.format);
    _setState('last_pull_at', now.toUtc().toIso8601String());
    _clearWindow();
  });

  void _applyItem(PullItem item, int generation) {
    final id = uuidBytes(item.id);
    final data = item.data;
    switch (item.type) {
      case 'product':
        if (data == null) {
          _db.execute('DELETE FROM product WHERE id = ?', [id]);
        } else {
          _upsertProduct(id, data, generation);
        }
      case 'stock':
        if (data == null) {
          _db.execute('DELETE FROM stock WHERE product_id = ?', [id]);
          _db.execute('DELETE FROM stock_batch WHERE product_id = ?', [id]);
        } else {
          _upsertStock(id, data);
        }
      case 'user':
        if (data == null) {
          _db.execute('DELETE FROM app_user WHERE id = ?', [id]);
        } else {
          _db.execute(
            'INSERT INTO app_user (id, code, name, is_admin, roles, permissions, limits, seen_generation) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET code = excluded.code, '
            'name = excluded.name, is_admin = excluded.is_admin, roles = excluded.roles, '
            'permissions = excluded.permissions, limits = excluded.limits, seen_generation = excluded.seen_generation',
            [
              id,
              data['code'],
              data['name'],
              data['is_admin'] == true ? 1 : 0,
              jsonEncode(data['roles'] ?? const []),
              jsonEncode(data['permissions'] ?? const []),
              jsonEncode(data['limits'] ?? const {}),
              generation,
            ],
          );
        }
      case 'fiscal':
        if (data == null) {
          _db.execute('DELETE FROM fiscal WHERE id = ?', [id]);
        } else {
          _upsertFiscal(id, data, generation);
        }
      default:
        // Tipo novo de uma versão mais nova da central: fica para a próxima atualização do PDV.
        break;
    }
  }

  void _upsertProduct(Uint8List id, Map<String, dynamic> data, int generation) {
    _db.execute(
      'INSERT INTO product (id, code, name, manufacturer, active_ingredient, controlled_class, ms_registration, '
      'ncm, cest, status, price_cents, fraction_milli, batch_required, seen_generation) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      'code = excluded.code, name = excluded.name, manufacturer = excluded.manufacturer, '
      'active_ingredient = excluded.active_ingredient, controlled_class = excluded.controlled_class, '
      'ms_registration = excluded.ms_registration, ncm = excluded.ncm, cest = excluded.cest, '
      'status = excluded.status, price_cents = excluded.price_cents, fraction_milli = excluded.fraction_milli, '
      'batch_required = excluded.batch_required, seen_generation = excluded.seen_generation',
      [
        id,
        data['code'],
        data['name'],
        data['manufacturer'],
        data['active_ingredient'],
        data['controlled_class'],
        data['ms_registration'],
        data['ncm'],
        data['cest'],
        data['status'],
        toCents(data['price']),
        toMilli(data['fraction_quantity']) ?? 1000,
        data['batch_required'] == true ? 1 : 0,
        generation,
      ],
    );
    _db.execute('DELETE FROM product_barcode WHERE product_id = ?', [id]);
    for (final barcode in (data['barcodes'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      _db.execute(
        'INSERT INTO product_barcode (id, product_id, code, is_primary, fraction_milli) VALUES (?, ?, ?, ?, ?)',
        [
          uuidBytes(barcode['id'] as String),
          id,
          barcode['code'],
          barcode['is_primary'] == true ? 1 : 0,
          toMilli(barcode['fraction_quantity']),
        ],
      );
    }
    _db.execute('DELETE FROM product_tax WHERE product_id = ?', [id]);
    for (final tax in (data['taxes'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      _db.execute(
        'INSERT INTO product_tax (id, product_id, valid_from, data) VALUES (?, ?, ?, ?)',
        [uuidBytes(tax['id'] as String), id, tax['valid_from'], jsonEncode(tax)],
      );
    }
  }

  void _upsertStock(Uint8List productId, Map<String, dynamic> data) {
    // O estoque só existe junto com o produto.
    if (_db.select('SELECT 1 FROM product WHERE id = ?', [productId]).isEmpty) return;
    _db.execute(
      'INSERT INTO stock (product_id, quantity_milli) VALUES (?, ?) '
      'ON CONFLICT (product_id) DO UPDATE SET quantity_milli = excluded.quantity_milli',
      [productId, toMilli(data['quantity']) ?? 0],
    );
    _db.execute('DELETE FROM stock_batch WHERE product_id = ?', [productId]);
    for (final batch in (data['batches'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      _db.execute(
        'INSERT INTO stock_batch (id, product_id, number, expires_on, quantity_milli) VALUES (?, ?, ?, ?, ?)',
        [
          uuidBytes(batch['id'] as String),
          productId,
          batch['number'],
          batch['expires_on'],
          toMilli(batch['quantity']) ?? 0,
        ],
      );
    }
  }

  void _upsertFiscal(Uint8List id, Map<String, dynamic> data, int generation) {
    _db.execute(
      'INSERT INTO fiscal (id, data, seen_generation) VALUES (?, ?, ?) '
      'ON CONFLICT (id) DO UPDATE SET data = excluded.data, seen_generation = excluded.seen_generation',
      [id, jsonEncode(data), generation],
    );
    final series = (data['series'] as List? ?? const []).cast<Map<String, dynamic>>();
    _db.execute('UPDATE fiscal_series SET active = 0');
    for (final entry in series) {
      _db.execute(
        'INSERT INTO fiscal_series (id, model, series, initial_number, central_last_used_number, active) '
        'VALUES (?, ?, ?, ?, ?, 1) ON CONFLICT (id) DO UPDATE SET model = excluded.model, '
        'series = excluded.series, initial_number = excluded.initial_number, '
        'central_last_used_number = excluded.central_last_used_number, active = 1',
        [
          uuidBytes(entry['id'] as String),
          entry['model'],
          entry['series'],
          entry['initial_number'],
          entry['last_used_number'],
        ],
      );
    }
  }

  /// Produto pela leitura do código de barras.
  LocalProduct? productByBarcode(String code) {
    final rows = _db.select(
      'SELECT p.id, p.code, p.name, p.status, p.price_cents, COALESCE(s.quantity_milli, 0) AS stock_milli '
      'FROM product_barcode b JOIN product p ON p.id = b.product_id '
      'LEFT JOIN stock s ON s.product_id = p.id WHERE b.code = ? LIMIT 1',
      [code],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LocalProduct(
      id: uuidText(row['id'] as List<int>),
      code: row['code'] as int,
      name: row['name'] as String,
      status: row['status'] as String,
      priceCents: row['price_cents'] as int?,
      stockMilli: row['stock_milli'] as int,
    );
  }

  /// Contagens para o log e para a tela: nenhum dado pessoal.
  Map<String, int> counts() => {
    for (final table in ['product', 'product_barcode', 'stock_batch', 'app_user', 'fiscal_series'])
      table: _db.select('SELECT count(*) AS n FROM $table').first['n'] as int,
  };

  /// Leitura direta, só para os testes.
  ResultSet debugSelect(String sql, [List<Object?> parameters = const []]) =>
      _db.select(sql, parameters);
}
