import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../core/local_logger.dart';
import '../core/secret_store.dart';
import '../core/text_fold.dart';

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
  // Outbox: o que sobe para a central, gravado na mesma transação da operação local.
  '''
  CREATE TABLE outbox (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sequence INTEGER NOT NULL UNIQUE CHECK (sequence > 0),
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    sent_at TEXT,
    result TEXT CHECK (result IN ('applied', 'conflict')),
    result_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB,
    CHECK ((sent_at IS NULL) = (result IS NULL))
  ) STRICT;
  CREATE INDEX outbox_pending_idx ON outbox (sequence) WHERE sent_at IS NULL;
  ''',
  // Clientes buscados neste terminal. Ficam criptografados com o resto do banco local.
  '''
  CREATE TABLE customer (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    code INTEGER NOT NULL,
    person_type TEXT NOT NULL,
    name TEXT NOT NULL,
    trade_name TEXT,
    document TEXT NOT NULL,
    birth_date TEXT,
    phone TEXT,
    email TEXT,
    postal_code TEXT,
    street TEXT,
    street_number TEXT,
    complement TEXT,
    district TEXT,
    city TEXT,
    city_code TEXT,
    state TEXT,
    search_text TEXT NOT NULL,
    saved_at TEXT NOT NULL
  ) STRICT;
  CREATE INDEX customer_code_idx ON customer (code);
  CREATE INDEX customer_document_idx ON customer (document);
  ''',
  // Caixa: PIN, busca de produto, turno e vendas locais (comprovante, reimpressão e fechamento).
  '''
  ALTER TABLE app_user ADD COLUMN pin_hash TEXT;

  -- Busca por nome, princípio ativo e fabricante, sem acento. O código de barras vai em product_barcode.
  CREATE VIRTUAL TABLE product_search USING fts5(
    product_id UNINDEXED, name, active_ingredient, manufacturer,
    tokenize = 'unicode61 remove_diacritics 2'
  );
  INSERT INTO product_search (product_id, name, active_ingredient, manufacturer)
  SELECT id, name, active_ingredient, manufacturer FROM product;

  -- Tentativas erradas de PIN por pessoa, neste terminal.
  CREATE TABLE pin_attempt (
    user_id BLOB PRIMARY KEY CHECK (length(user_id) = 16),
    failures INTEGER NOT NULL,
    locked_until TEXT
  ) STRICT;

  CREATE TABLE cash_session (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    operator_id BLOB NOT NULL,
    operator_name TEXT NOT NULL,
    opened_at TEXT NOT NULL,
    opening_float_cents INTEGER NOT NULL CHECK (opening_float_cents >= 0),
    status TEXT NOT NULL CHECK (status IN ('open', 'closed')),
    closed_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;

  CREATE TABLE sale (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    number INTEGER NOT NULL UNIQUE CHECK (number > 0),
    code TEXT NOT NULL,
    cash_session_id BLOB NOT NULL REFERENCES cash_session (id),
    operator_id BLOB NOT NULL,
    customer_id BLOB,
    sold_at TEXT NOT NULL,
    subtotal_cents INTEGER NOT NULL,
    discount_cents INTEGER NOT NULL,
    total_cents INTEGER NOT NULL,
    fiscal_model TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE INDEX sale_session_idx ON sale (cash_session_id);

  CREATE TABLE sale_item (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL REFERENCES sale (id),
    line INTEGER NOT NULL,
    product_id BLOB NOT NULL,
    product_code INTEGER NOT NULL,
    product_name TEXT NOT NULL,
    quantity_milli INTEGER NOT NULL,
    unit_price_cents INTEGER NOT NULL,
    discount_cents INTEGER NOT NULL,
    total_cents INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE INDEX sale_item_sale_idx ON sale_item (sale_id);

  CREATE TABLE sale_payment (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL REFERENCES sale (id),
    method TEXT NOT NULL,
    amount_cents INTEGER NOT NULL,
    change_cents INTEGER NOT NULL,
    card_brand TEXT,
    authorization_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE INDEX sale_payment_sale_idx ON sale_payment (sale_id);
  ''',
  // Desconto máximo do produto (centésimos de ponto percentual) e convênios do cliente.
  '''
  ALTER TABLE product ADD COLUMN max_discount_bp INTEGER;
  ALTER TABLE product ADD COLUMN max_discount_until TEXT;
  ALTER TABLE customer ADD COLUMN agreements TEXT NOT NULL DEFAULT '[]';
  ''',
  // Sangria, suprimento e fechamento do caixa (com o que foi contado).
  '''
  CREATE TABLE cash_movement (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    cash_session_id BLOB NOT NULL REFERENCES cash_session (id),
    kind TEXT NOT NULL CHECK (kind IN ('withdrawal', 'supply')),
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    reason TEXT NOT NULL,
    operator_id BLOB NOT NULL,
    released_by BLOB,
    moved_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE INDEX cash_movement_session_idx ON cash_movement (cash_session_id);
  ALTER TABLE cash_session ADD COLUMN closed_by BLOB;
  ALTER TABLE cash_session ADD COLUMN counted TEXT;
  ''',
  // Orçamento (terminal de orçamento) e o vendedor da venda.
  '''
  CREATE TABLE quote (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    number INTEGER NOT NULL UNIQUE CHECK (number > 0),
    code TEXT NOT NULL,
    seller_id BLOB NOT NULL,
    customer_id BLOB,
    card_number INTEGER,
    quoted_at TEXT NOT NULL,
    total_cents INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  ALTER TABLE sale ADD COLUMN seller_id BLOB;
  ''',
];

/// Pessoa que pode entrar no PDV, com o que veio da central.
class LocalUser {
  const LocalUser({
    required this.id,
    required this.code,
    required this.name,
    required this.isAdmin,
    required this.permissions,
    required this.limits,
    this.pinHash,
  });

  final String id;
  final int code;
  final String name;
  final bool isAdmin;
  final List<String> permissions;

  /// Limites por tipo; vazio (null) é sem teto.
  final Map<String, num?> limits;
  final String? pinHash;

  bool can(String permission) => isAdmin || permissions.contains(permission);
}

/// Produto para a venda, com o que o caixa precisa para avisar e cobrar.
class SaleProduct {
  const SaleProduct({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.priceCents,
    required this.stockMilli,
    required this.fractionMilli,
    this.manufacturer,
    this.activeIngredient,
    this.controlledClass,
    this.barcodeId,
    this.barcodeFractionMilli,
    this.maxDiscountBp,
    this.maxDiscountUntil,
  });

  /// Desconto máximo em centésimos de ponto (750 = 7,5%); vazio é sem regra.
  final int? maxDiscountBp;
  final DateTime? maxDiscountUntil;

  /// Regra de desconto que vale agora (a que já venceu não vale).
  int? maxDiscountAt(DateTime now) =>
      maxDiscountBp != null && (maxDiscountUntil == null || maxDiscountUntil!.isAfter(now)) ? maxDiscountBp : null;

  final String id;
  final int code;
  final String name;
  final String status;
  final int? priceCents;
  final int stockMilli;
  final int fractionMilli;
  final String? manufacturer;
  final String? activeIngredient;
  final String? controlledClass;

  /// Código lido, quando o produto veio pela leitura.
  final String? barcodeId;
  final int? barcodeFractionMilli;
}

/// Turno aberto neste terminal.
class LocalCashSession {
  const LocalCashSession({
    required this.id,
    required this.operatorId,
    required this.operatorName,
    required this.openedAt,
    required this.openingFloatCents,
  });

  final String id;
  final String operatorId;
  final String operatorName;
  final DateTime openedAt;
  final int openingFloatCents;
}

/// Documento mascarado, igual ao da central: 123.***.***-09 ou 12.345.***/****-90.
String? maskDocument(String? document) {
  if (document == null) return null;
  if (document.length == 11) {
    return '${document.substring(0, 3)}.***.***-${document.substring(9)}';
  }
  if (document.length == 14) {
    return '${document.substring(0, 2)}.${document.substring(2, 5)}.***/****-${document.substring(12)}';
  }
  return null;
}

/// Texto para busca sem acento nem maiúscula, como a central faz.
String normalizeSearch(String value) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final lower = value.toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.split('')) {
    final index = from.indexOf(char);
    buffer.write(index >= 0 ? to[index] : char);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Cliente na lista de busca: o documento vem mascarado.
class CustomerSummary {
  const CustomerSummary({
    required this.id,
    required this.code,
    required this.personType,
    required this.name,
    this.tradeName,
    this.documentMasked,
    this.city,
    this.state,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> json) => CustomerSummary(
    id: json['id'] as String,
    code: json['code'] as int,
    personType: json['person_type'] as String,
    name: json['name'] as String,
    tradeName: json['trade_name'] as String?,
    documentMasked: json['document_masked'] as String?,
    city: json['city'] as String?,
    state: json['state'] as String?,
  );

  final String id;
  final int code;
  final String personType;
  final String name;
  final String? tradeName;
  final String? documentMasked;
  final String? city;
  final String? state;
}

/// Logs que esperam envio além deste número não entram na outbox: ficam só no arquivo local.
const maxPendingLogs = 5000;

/// Item da outbox pronto para subir.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.sequence,
    required this.kind,
    required this.payload,
  });

  final String id;
  final int sequence;
  final String kind;
  final Map<String, dynamic> payload;

  Map<String, Object?> toJson() => {
    'id': id,
    'sequence': sequence,
    'kind': kind,
    'payload': payload,
  };
}

/// Resposta da central para um item.
class PushResult {
  const PushResult({required this.id, required this.status, this.result, this.code});

  factory PushResult.fromJson(Map<String, dynamic> json) => PushResult(
    id: json['id'] as String,
    status: json['status'] as String,
    result: json['result'] as String?,
    code: json['code'] as String?,
  );

  final String id;

  /// applied, conflict ou duplicate (já recebido; [result] diz como ficou).
  final String status;
  final String? result;
  final String? code;

  /// Como o item ficou na central.
  String get outcome => status == 'duplicate' ? (result ?? 'applied') : status;
}

/// Banco local do PDV: cópia enxuta da filial, criptografada no disco.
class LocalDatabase {
  LocalDatabase._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    // Texto sem acento e em minúsculas, para a busca com "%" entre as palavras.
    _db.createFunction(
      functionName: 'pdv_fold',
      function: (args) => foldText(args[0] as String?),
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
    );
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

  /// Executa uma operação local junto com a outbox: ou grava tudo, ou nada.
  T transaction<T>(T Function() action) => _transaction(action);

  T _transaction<T>(T Function() action) {
    // Já dentro de uma transação (operação que também grava na outbox): segue nela.
    if (!_db.autocommit) return action();
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
      _db.execute('DELETE FROM product_search WHERE product_id NOT IN (SELECT id FROM product)');
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
          _db.execute('DELETE FROM product_search WHERE product_id = ?', [id]);
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
            'INSERT INTO app_user (id, code, name, is_admin, roles, permissions, limits, pin_hash, seen_generation) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET code = excluded.code, '
            'name = excluded.name, is_admin = excluded.is_admin, roles = excluded.roles, '
            'permissions = excluded.permissions, limits = excluded.limits, pin_hash = excluded.pin_hash, '
            'seen_generation = excluded.seen_generation',
            [
              id,
              data['code'],
              data['name'],
              data['is_admin'] == true ? 1 : 0,
              jsonEncode(data['roles'] ?? const []),
              jsonEncode(data['permissions'] ?? const []),
              jsonEncode(data['limits'] ?? const {}),
              data['pin_hash'],
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
      case 'customer':
        if (data == null) {
          _db.execute('DELETE FROM customer WHERE id = ?', [id]);
        } else {
          _upsertCustomer(id, data);
        }
      default:
        // Tipo novo de uma versão mais nova da central: fica para a próxima atualização do PDV.
        break;
    }
  }

  void _upsertProduct(Uint8List id, Map<String, dynamic> data, int generation) {
    _db.execute(
      'INSERT INTO product (id, code, name, manufacturer, active_ingredient, controlled_class, ms_registration, '
      'ncm, cest, status, price_cents, fraction_milli, batch_required, seen_generation, max_discount_bp, max_discount_until) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      'max_discount_bp = excluded.max_discount_bp, max_discount_until = excluded.max_discount_until, '
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
        data['max_discount'] == null ? null : ((data['max_discount'] as num) * 100).round(),
        data['max_discount_until'],
      ],
    );
    _db.execute('DELETE FROM product_search WHERE product_id = ?', [id]);
    _db.execute(
      'INSERT INTO product_search (product_id, name, active_ingredient, manufacturer) VALUES (?, ?, ?, ?)',
      [id, data['name'], data['active_ingredient'], data['manufacturer']],
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

  /// Acrescenta um item na outbox. Chamado dentro de [transaction], fica na mesma transação.
  String enqueue(
    String kind,
    Map<String, Object?> payload, {
    required DateTime now,
    String? traceId,
  }) => _transaction(() {
    final id = const Uuid().v7();
    final next = _db.select('SELECT COALESCE(max(sequence), 0) + 1 AS n FROM outbox').first['n'] as int;
    final stamp = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO outbox (id, sequence, kind, payload, created_at, updated_at, trace_id) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [uuidBytes(id), next, kind, jsonEncode(payload), stamp, stamp, traceId == null ? null : uuidBytes(traceId)],
    );
    return id;
  });

  /// Aviso ou erro do log local, para subir. Sem espaço na fila, fica só no arquivo.
  void enqueueLog(Map<String, Object?> entry, {required DateTime now}) {
    final level = entry['level'];
    if (level != 'warn' && level != 'error') return;
    final pending = _db.select(
      "SELECT count(*) AS n FROM outbox WHERE sent_at IS NULL AND kind = 'log'",
    ).first['n'] as int;
    if (pending >= maxPendingLogs) return;
    const standard = {'level', 'time', 'msg', 'trace_id', 'version', 'service', 'error_code'};
    String? text(Object? value, int max) {
      if (value == null) return null;
      final string = value.toString();
      return string.length > max ? string.substring(0, max) : string;
    }

    final fields = <String, Object?>{
      for (final item in entry.entries)
        if (!standard.contains(item.key))
          item.key: item.value is String ? text(item.value, 2000) : item.value,
    };
    var fieldsJson = jsonEncode(fields);
    // A central aceita até 8 KB de campos; o excesso fica só no arquivo local.
    if (utf8.encode(fieldsJson).length > 8000) {
      fieldsJson = jsonEncode({'truncated': true, 'keys': fields.keys.take(50).toList()});
    }
    final rawTrace = entry['trace_id'];
    final traceId = rawTrace is String && Uuid.isValidUUID(fromString: rawTrace) ? rawTrace : null;
    final rawCode = entry['error_code'];
    final errorCode = rawCode is String && RegExp(r'^FA\d{3}$').hasMatch(rawCode) ? rawCode : null;
    final time = entry['time'];
    enqueue(
      'log',
      {
        'level': level,
        'time': time is String ? time : now.toUtc().toIso8601String(),
        'msg': text(entry['msg'], 500) ?? '(sem mensagem)',
        'error_code': ?errorCode,
        'trace_id': ?traceId,
        'version': ?text(entry['version'], 50),
        'fields': jsonDecode(fieldsJson),
      },
      now: now,
      traceId: traceId,
    );
  }

  /// Quantos itens esperam envio (vai no sinal de vida).
  int get outboxPending =>
      _db.select('SELECT count(*) AS n FROM outbox WHERE sent_at IS NULL').first['n'] as int;

  /// Próximo pacote, em ordem, limitado por quantidade e por tamanho.
  List<OutboxItem> nextOutboxBatch({int maxItems = 100, int maxBytes = 64 * 1024}) {
    final rows = _db.select(
      'SELECT id, sequence, kind, payload FROM outbox WHERE sent_at IS NULL ORDER BY sequence LIMIT ?',
      [maxItems],
    );
    final batch = <OutboxItem>[];
    var bytes = 0;
    for (final row in rows) {
      final payload = row['payload'] as String;
      bytes += utf8.encode(payload).length + 120;
      if (batch.isNotEmpty && bytes > maxBytes) break;
      batch.add(
        OutboxItem(
          id: uuidText(row['id'] as List<int>),
          sequence: row['sequence'] as int,
          kind: row['kind'] as String,
          payload: jsonDecode(payload) as Map<String, dynamic>,
        ),
      );
    }
    return batch;
  }

  /// Grava a resposta da central. Item sem resposta continua na fila.
  void markSent(List<OutboxItem> sent, List<PushResult> results, {required DateTime now}) =>
      _transaction(() {
        final stamp = now.toUtc().toIso8601String();
        final byId = {for (final result in results) result.id: result};
        for (final item in sent) {
          final result = byId[item.id];
          if (result == null) {
            _db.execute(
              'UPDATE outbox SET attempts = attempts + 1, updated_at = ?, version = version + 1 WHERE id = ?',
              [stamp, uuidBytes(item.id)],
            );
            continue;
          }
          _db.execute(
            'UPDATE outbox SET sent_at = ?, result = ?, result_code = ?, attempts = attempts + 1, '
            'updated_at = ?, version = version + 1 WHERE id = ?',
            [stamp, result.outcome, result.code, stamp, uuidBytes(item.id)],
          );
        }
        // Logs já entregues saem da fila local depois de 7 dias; o registro fica na central.
        _db.execute(
          "DELETE FROM outbox WHERE kind = 'log' AND sent_at IS NOT NULL AND sent_at < ?",
          [now.toUtc().subtract(const Duration(days: 7)).toIso8601String()],
        );
      });

  void _upsertCustomer(Uint8List id, Map<String, dynamic> data) {
    const columns = [
      'code', 'person_type', 'name', 'trade_name', 'document', 'birth_date', 'phone', 'email', 'postal_code',
      'street', 'street_number', 'complement', 'district', 'city', 'city_code', 'state', 'agreements',
    ];
    final search = normalizeSearch('${data['name'] ?? ''} ${data['trade_name'] ?? ''}');
    _db.execute(
      'INSERT INTO customer (id, ${columns.join(', ')}, search_text, saved_at) '
      'VALUES (?, ${List.filled(columns.length, '?').join(', ')}, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      '${columns.map((c) => '$c = excluded.$c').join(', ')}, search_text = excluded.search_text, saved_at = excluded.saved_at',
      [
        id,
        for (final c in columns) c == 'agreements' ? jsonEncode(data[c] ?? const []) : data[c],
        search,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  /// Guarda o cliente escolhido no PDV (vindo da central). Vazio: o cliente não existe mais.
  void saveCustomer(PullItem item) => _transaction(() => _applyItem(item, syncState.generation));

  /// Cliente guardado neste terminal, com os dados completos para a venda.
  Map<String, Object?>? customerById(String id) {
    final rows = _db.select('SELECT * FROM customer WHERE id = ?', [uuidBytes(id)]);
    if (rows.isEmpty) return null;
    final row = Map<String, Object?>.from(rows.first)..remove('search_text');
    row['id'] = id;
    row['agreements'] = jsonDecode(row['agreements'] as String? ?? '[]');
    return row;
  }

  /// Busca sem internet, só entre os clientes já guardados: nome, código ou CPF/CNPJ.
  List<CustomerSummary> searchLocalCustomers(String query) {
    final text = query.trim();
    final digits = text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    final words = normalizeSearch(text).split(' ').where((word) => word.isNotEmpty).toList();
    final byName = RegExp(r'[0-9]').hasMatch(text) ? <String>[] : words;
    final rows = _db.select(
      'SELECT id, code, person_type, name, trade_name, document, city, state FROM customer '
      "WHERE CAST(code AS TEXT) = ? OR document = ? ${byName.isEmpty ? '' : 'OR (${byName.map((_) => "search_text LIKE ? ESCAPE '\\'").join(' AND ')})'} "
      'ORDER BY name, id LIMIT 20',
      [
        text,
        digits,
        for (final word in byName) '%${word.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%',
      ],
    );
    return [
      for (final row in rows)
        CustomerSummary(
          id: uuidText(row['id'] as List<int>),
          code: row['code'] as int,
          personType: row['person_type'] as String,
          name: row['name'] as String,
          tradeName: row['trade_name'] as String?,
          documentMasked: maskDocument(row['document'] as String?),
          city: row['city'] as String?,
          state: row['state'] as String?,
        ),
    ];
  }

  /// Pessoa pelo código, para a entrada no PDV.
  LocalUser? userByCode(int code) {
    final rows = _db.select('SELECT * FROM app_user WHERE code = ? LIMIT 1', [code]);
    if (rows.isEmpty) return null;
    return _user(rows.first);
  }

  LocalUser? userById(String id) {
    final rows = _db.select('SELECT * FROM app_user WHERE id = ?', [uuidBytes(id)]);
    return rows.isEmpty ? null : _user(rows.first);
  }

  LocalUser _user(Row row) => LocalUser(
    id: uuidText(row['id'] as List<int>),
    code: row['code'] as int,
    name: row['name'] as String,
    isAdmin: row['is_admin'] == 1,
    permissions: (jsonDecode(row['permissions'] as String) as List).cast<String>(),
    limits: (jsonDecode(row['limits'] as String) as Map).map((key, value) => MapEntry(key as String, value as num?)),
    pinHash: row['pin_hash'] as String?,
  );

  /// Tentativas erradas e bloqueio do PIN desta pessoa neste terminal.
  ({int failures, DateTime? lockedUntil}) pinAttempts(String userId) {
    final rows = _db.select('SELECT failures, locked_until FROM pin_attempt WHERE user_id = ?', [uuidBytes(userId)]);
    if (rows.isEmpty) return (failures: 0, lockedUntil: null);
    return (
      failures: rows.first['failures'] as int,
      lockedUntil: DateTime.tryParse(rows.first['locked_until'] as String? ?? ''),
    );
  }

  void recordPinAttempt(String userId, {required int failures, DateTime? lockedUntil}) => _db.execute(
    'INSERT INTO pin_attempt (user_id, failures, locked_until) VALUES (?, ?, ?) '
    'ON CONFLICT (user_id) DO UPDATE SET failures = excluded.failures, locked_until = excluded.locked_until',
    [uuidBytes(userId), failures, lockedUntil?.toUtc().toIso8601String()],
  );

  /// Produto pela leitura: o código de barras primeiro; sem ele, o código do produto.
  SaleProduct? saleProductByCode(String code) {
    final byBarcode = _db.select(
      'SELECT p.*, COALESCE(s.quantity_milli, 0) AS stock_milli, b.id AS barcode_id, b.fraction_milli AS barcode_fraction '
      'FROM product_barcode b JOIN product p ON p.id = b.product_id LEFT JOIN stock s ON s.product_id = p.id '
      'WHERE b.code = ? LIMIT 1',
      [code],
    );
    if (byBarcode.isNotEmpty) return _saleProduct(byBarcode.first);
    final number = int.tryParse(code);
    if (number == null) return null;
    final byCode = _db.select(
      'SELECT p.*, COALESCE(s.quantity_milli, 0) AS stock_milli, NULL AS barcode_id, NULL AS barcode_fraction '
      'FROM product p LEFT JOIN stock s ON s.product_id = p.id WHERE p.code = ? LIMIT 1',
      [number],
    );
    return byCode.isEmpty ? null : _saleProduct(byCode.first);
  }

  /// Produto pelo identificador (para o orçamento e o recálculo do preço).
  SaleProduct? saleProductById(String id) {
    final rows = _db.select(
      'SELECT p.*, COALESCE(s.quantity_milli, 0) AS stock_milli, NULL AS barcode_id, NULL AS barcode_fraction '
      'FROM product p LEFT JOIN stock s ON s.product_id = p.id WHERE p.id = ? LIMIT 1',
      [uuidBytes(id)],
    );
    return rows.isEmpty ? null : _saleProduct(rows.first);
  }

  /// Busca por nome, princípio ativo ou fabricante, sem acento e sem diferença de maiúsculas.
  /// O espaço vale como "%": "dip 500" acha "Dipirona Sódica 500 mg", e pedaço do meio da palavra
  /// também vale ("pirona"). Primeiro vêm os que começam as palavras (índice de texto, pelo nome),
  /// depois os que só contêm os pedaços, na ordem digitada.
  List<SaleProduct> searchSaleProducts(String query, {int limit = 30}) {
    final words = foldText(query).split(' ').where((word) => word.isNotEmpty).take(6).toList();
    if (words.isEmpty) return const [];
    const columns = 'p.*, COALESCE(s.quantity_milli, 0) AS stock_milli, NULL AS barcode_id, NULL AS barcode_fraction';
    final byWords = _db.select(
      'SELECT $columns FROM product_search f JOIN product p ON p.id = f.product_id LEFT JOIN stock s ON s.product_id = p.id '
      'WHERE product_search MATCH ? ORDER BY bm25(product_search, 0, 10, 4, 2), p.name LIMIT ?',
      [words.map((word) => '"$word"*').join(' '), limit],
    );
    final found = byWords.map(_saleProduct).toList();
    if (found.length >= limit) return found;
    final seen = {for (final product in found) product.id};
    final pattern = '%${words.join('%')}%';
    final byPieces = _db.select(
      'SELECT $columns FROM product p LEFT JOIN stock s ON s.product_id = p.id '
      "WHERE pdv_fold(p.name || ' ' || COALESCE(p.active_ingredient, '') || ' ' || COALESCE(p.manufacturer, '')) LIKE ? "
      'ORDER BY pdv_fold(p.name) LIKE ? DESC, p.name LIMIT ?',
      [pattern, pattern, limit * 2],
    );
    for (final row in byPieces) {
      final product = _saleProduct(row);
      if (seen.add(product.id)) found.add(product);
      if (found.length >= limit) break;
    }
    return found;
  }

  /// Dados de cadastro do produto que o terminal tem, para a consulta no caixa.
  Map<String, Object?>? productDetails(String id) {
    final rows = _db.select(
      'SELECT p.*, s.quantity_milli AS stock_milli FROM product p LEFT JOIN stock s ON s.product_id = p.id WHERE p.id = ?',
      [uuidBytes(id)],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'code': row['code'],
      'name': row['name'],
      'active_ingredient': row['active_ingredient'],
      'manufacturer': row['manufacturer'],
      'controlled_class': row['controlled_class'],
      'ms_registration': row['ms_registration'],
      'ncm': row['ncm'],
      'cest': row['cest'],
      'status': row['status'],
      'price_cents': row['price_cents'],
      'fraction_milli': row['fraction_milli'],
      'batch_required': row['batch_required'] == 1,
      'max_discount_bp': row['max_discount_bp'],
      'max_discount_until': row['max_discount_until'],
      'stock_milli': row['stock_milli'],
      'barcodes': [
        for (final barcode in _db.select(
          'SELECT code, is_primary, fraction_milli FROM product_barcode WHERE product_id = ? ORDER BY is_primary DESC, code',
          [uuidBytes(id)],
        ))
          {'code': barcode['code'], 'primary': barcode['is_primary'] == 1, 'fraction_milli': barcode['fraction_milli']},
      ],
      'batches': [
        for (final batch in batchesOf(id)) {'number': batch.number, 'expires_on': batch.expiresOn, 'quantity_milli': batch.quantityMilli},
      ],
    };
  }

  /// Lotes do produto na cópia local, o que vence primeiro antes (FEFO).
  List<({String id, String number, String expiresOn, int quantityMilli})> batchesOf(String productId) => _db
      .select(
        'SELECT id, number, expires_on, quantity_milli FROM stock_batch WHERE product_id = ? ORDER BY expires_on, number',
        [uuidBytes(productId)],
      )
      .map((row) => (
            id: uuidText(row['id'] as List<int>),
            number: row['number'] as String,
            expiresOn: row['expires_on'] as String,
            quantityMilli: row['quantity_milli'] as int,
          ))
      .toList();

  SaleProduct _saleProduct(Row row) => SaleProduct(
    id: uuidText(row['id'] as List<int>),
    code: row['code'] as int,
    name: row['name'] as String,
    status: row['status'] as String,
    priceCents: row['price_cents'] as int?,
    stockMilli: row['stock_milli'] as int,
    fractionMilli: row['fraction_milli'] as int,
    manufacturer: row['manufacturer'] as String?,
    activeIngredient: row['active_ingredient'] as String?,
    controlledClass: row['controlled_class'] as String?,
    barcodeId: row['barcode_id'] == null ? null : uuidText(row['barcode_id'] as List<int>),
    barcodeFractionMilli: row['barcode_fraction'] as int?,
    maxDiscountBp: row['max_discount_bp'] as int?,
    maxDiscountUntil: DateTime.tryParse(row['max_discount_until'] as String? ?? ''),
  );

  /// Dados da filial e da empresa (para o comprovante) e o último número que a central conhece.
  Map<String, dynamic>? get fiscal {
    final rows = _db.select('SELECT data FROM fiscal LIMIT 1');
    return rows.isEmpty ? null : jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
  }

  /// Turno aberto neste terminal, se houver.
  LocalCashSession? get openCashSession {
    final rows = _db.select(
      "SELECT * FROM cash_session WHERE status = 'open' AND deleted_at IS NULL ORDER BY opened_at DESC LIMIT 1",
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LocalCashSession(
      id: uuidText(row['id'] as List<int>),
      operatorId: uuidText(row['operator_id'] as List<int>),
      operatorName: row['operator_name'] as String,
      openedAt: DateTime.parse(row['opened_at'] as String),
      openingFloatCents: row['opening_float_cents'] as int,
    );
  }

  /// Abre o turno: grava aqui e põe na outbox, na mesma transação.
  LocalCashSession openSession({
    required LocalUser operator,
    required int openingFloatCents,
    required DateTime now,
  }) => _transaction(() {
    final id = const Uuid().v7();
    final at = now.toUtc().toIso8601String();
    _db.execute(
      "INSERT INTO cash_session (id, operator_id, operator_name, opened_at, opening_float_cents, status, created_at, updated_at) "
      "VALUES (?, ?, ?, ?, ?, 'open', ?, ?)",
      [uuidBytes(id), uuidBytes(operator.id), operator.name, at, openingFloatCents, at, at],
    );
    enqueue('cash_session_open', {
      'id': id,
      'operator_id': operator.id,
      'opened_at': at,
      'opening_float': openingFloatCents / 100,
    }, now: now);
    return LocalCashSession(
      id: id,
      operatorId: operator.id,
      operatorName: operator.name,
      openedAt: now.toUtc(),
      openingFloatCents: openingFloatCents,
    );
  });

  /// Próximo número de venda do terminal: nunca repete, nem se o banco local se perder, porque a
  /// central informa o último que recebeu.
  /// Perfil do terminal na central: `quote` (orçamento), `cashier` (caixa) ou `self_service`.
  String get terminalProfile => fiscal?['terminal_profile'] as String? ?? 'cashier';

  /// A filial pede o PIN do vendedor junto com o código?
  bool get sellerPinRequired => fiscal?['seller_pin_required'] == true;

  /// Dias de validade do orçamento (0: até o fim do dia).
  int get quoteValidityDays => (fiscal?['quote_validity_days'] as num?)?.toInt() ?? 0;

  /// Vendedor fixo do terminal (autoatendimento).
  String? get fixedSellerId => fiscal?['fixed_seller_id'] as String?;

  /// Próximo número de orçamento deste terminal (continua do que a central conhece).
  int get nextQuoteNumber {
    final local = _db.select('SELECT COALESCE(max(number), 0) AS n FROM quote').first['n'] as int;
    final central = (fiscal?['last_quote_number'] as num?)?.toInt() ?? 0;
    return (local > central ? local : central) + 1;
  }

  /// Grava o orçamento e põe na outbox, na mesma transação.
  void saveQuote(Map<String, Object?> payload, {required String code, required DateTime now}) => _transaction(() {
    final at = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO quote (id, number, code, seller_id, customer_id, card_number, quoted_at, total_cents, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuidBytes(payload['id']! as String),
        payload['number'],
        code,
        uuidBytes(payload['seller_id']! as String),
        payload['customer_id'] == null ? null : uuidBytes(payload['customer_id']! as String),
        payload['card_number'],
        payload['quoted_at'],
        toCents(payload['total'])!,
        at,
        at,
      ],
    );
    enqueue('quote', payload, now: now);
  });

  int get nextSaleNumber {
    final local = _db.select('SELECT COALESCE(max(number), 0) AS n FROM sale').first['n'] as int;
    final central = (fiscal?['last_sale_number'] as num?)?.toInt() ?? 0;
    return (local > central ? local : central) + 1;
  }

  /// Grava a venda e põe na outbox, na mesma transação. [payload] é o que a central confere.
  void saveSale(Map<String, Object?> payload, {required String code, required List<Map<String, Object?>> itemRows, required DateTime now}) =>
      _transaction(() {
        final at = now.toUtc().toIso8601String();
        int cents(Object? value) => toCents(value)!;
        _db.execute(
          'INSERT INTO sale (id, number, code, cash_session_id, operator_id, customer_id, sold_at, subtotal_cents, '
          'discount_cents, total_cents, fiscal_model, created_at, updated_at, seller_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            uuidBytes(payload['id']! as String),
            payload['number'],
            code,
            uuidBytes(payload['cash_session_id']! as String),
            uuidBytes(payload['operator_id']! as String),
            payload['customer_id'] == null ? null : uuidBytes(payload['customer_id']! as String),
            payload['sold_at'],
            cents(payload['subtotal']),
            cents(payload['discount_total']),
            cents(payload['total']),
            payload['fiscal_model'],
            at,
            at,
            payload['seller_id'] == null ? null : uuidBytes(payload['seller_id']! as String),
          ],
        );
        for (final item in itemRows) {
          _db.execute(
            'INSERT INTO sale_item (id, sale_id, line, product_id, product_code, product_name, quantity_milli, '
            'unit_price_cents, discount_cents, total_cents, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              uuidBytes(item['id']! as String),
              uuidBytes(payload['id']! as String),
              item['line'],
              uuidBytes(item['product_id']! as String),
              item['product_code'],
              item['product_name'],
              item['quantity_milli'],
              item['unit_price_cents'],
              item['discount_cents'],
              item['total_cents'],
              at,
              at,
            ],
          );
        }
        for (final payment in (payload['payments']! as List).cast<Map<String, Object?>>()) {
          _db.execute(
            'INSERT INTO sale_payment (id, sale_id, method, amount_cents, change_cents, card_brand, authorization_code, '
            'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              uuidBytes(payment['id']! as String),
              uuidBytes(payload['id']! as String),
              payment['method'],
              cents(payment['amount']),
              toCents(payment['change']) ?? 0,
              payment['card_brand'],
              payment['authorization_code'],
              at,
              at,
            ],
          );
        }
        enqueue('sale', payload, now: now);
      });

  /// Dinheiro que deve estar na gaveta agora: fundo de troco + vendas em dinheiro (menos o troco)
  /// + suprimentos - sangrias. Só para conferir a sangria; o operador não vê este valor.
  int cashInDrawerCents(String sessionId) {
    final id = uuidBytes(sessionId);
    final row = _db.select(
      'SELECT '
      '(SELECT opening_float_cents FROM cash_session WHERE id = ?) '
      "+ COALESCE((SELECT SUM(p.amount_cents - p.change_cents) FROM sale_payment p JOIN sale s ON s.id = p.sale_id "
      "WHERE s.cash_session_id = ? AND p.method = 'cash'), 0) "
      "+ COALESCE((SELECT SUM(amount_cents) FROM cash_movement WHERE cash_session_id = ? AND kind = 'supply'), 0) "
      "- COALESCE((SELECT SUM(amount_cents) FROM cash_movement WHERE cash_session_id = ? AND kind = 'withdrawal'), 0) AS cents",
      [id, id, id, id],
    ).first;
    return row['cents'] as int? ?? 0;
  }

  /// Sangria ou suprimento: grava aqui e põe na outbox, na mesma transação.
  String recordCashMovement({
    required String sessionId,
    required String kind,
    required int amountCents,
    required String reason,
    required String operatorId,
    String? releasedBy,
    required DateTime now,
  }) => _transaction(() {
    final id = const Uuid().v7();
    final at = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO cash_movement (id, cash_session_id, kind, amount_cents, reason, operator_id, released_by, moved_at, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuidBytes(id), uuidBytes(sessionId), kind, amountCents, reason, uuidBytes(operatorId),
        releasedBy == null ? null : uuidBytes(releasedBy), at, at, at,
      ],
    );
    enqueue('cash_movement', {
      'id': id,
      'cash_session_id': sessionId,
      'kind': kind,
      'amount': amountCents / 100,
      'reason': reason,
      'operator_id': operatorId,
      'released_by': releasedBy,
      'moved_at': at,
    }, now: now);
    return id;
  });

  /// Fecha o turno com o que foi contado (em centavos, por forma). O esperado é calculado na central.
  void closeSession({
    required String sessionId,
    required String closedBy,
    required Map<String, int> countedCents,
    String? note,
    required DateTime now,
  }) => _transaction(() {
    final at = now.toUtc().toIso8601String();
    _db.execute(
      "UPDATE cash_session SET status = 'closed', closed_at = ?, closed_by = ?, counted = ?, updated_at = ?, "
      "version = version + 1 WHERE id = ? AND status = 'open'",
      [at, uuidBytes(closedBy), jsonEncode(countedCents), at, uuidBytes(sessionId)],
    );
    enqueue('cash_session_close', {
      'cash_session_id': sessionId,
      'closed_by': closedBy,
      'closed_at': at,
      'counts': {for (final entry in countedCents.entries) entry.key: entry.value / 100},
      'note': note,
    }, now: now);
  });

  /// Configuração local do terminal (por exemplo, a impressora).
  String? setting(String key) => _state('setting:$key');
  void setSetting(String key, String? value) => _setState('setting:$key', value);

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
