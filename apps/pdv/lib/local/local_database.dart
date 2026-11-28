import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../core/local_logger.dart';
import '../core/secret_store.dart';
import '../core/text_fold.dart';
import '../face/face_math.dart' show templateFromBytes;

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
  // Devolução: documento, itens e a sangria que paga a devolução em dinheiro.
  '''
  CREATE TABLE sale_return (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    number INTEGER NOT NULL UNIQUE CHECK (number > 0),
    code TEXT NOT NULL,
    sale_id BLOB NOT NULL,
    sale_code TEXT NOT NULL,
    destination TEXT NOT NULL CHECK (destination IN ('credit', 'agreement', 'cash')),
    total_cents INTEGER NOT NULL CHECK (total_cents > 0),
    paid INTEGER NOT NULL DEFAULT 0,
    returned_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE TABLE sale_return_item (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_return_id BLOB NOT NULL REFERENCES sale_return (id),
    sale_item_id BLOB NOT NULL,
    quantity_milli INTEGER NOT NULL,
    amount_cents INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  CREATE INDEX sale_return_item_sale_item_idx ON sale_return_item (sale_item_id);
  ALTER TABLE cash_movement ADD COLUMN return_id BLOB;
  ''',
  // Crédito de devolução usado como pagamento numa nova compra.
  '''
  ALTER TABLE sale_payment ADD COLUMN return_id BLOB;
  CREATE INDEX sale_payment_return_idx ON sale_payment (return_id) WHERE return_id IS NOT NULL;
  ''',
  // Forma de entrar no PDV de cada pessoa (qualquer uma, só PIN, só câmera ou só digital).
  '''
  ALTER TABLE app_user ADD COLUMN auth_mode TEXT NOT NULL DEFAULT 'pin';
  ''',
  // Código do rosto (128 números; nunca a imagem), para a comparação sem internet.
  '''
  ALTER TABLE app_user ADD COLUMN face_model TEXT;
  ALTER TABLE app_user ADD COLUMN face_template BLOB;
  ''',
  // Descontos automáticos: as regras, a hierarquia do produto e o grupo do cliente.
  '''
  CREATE TABLE discount_rule (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    data TEXT NOT NULL,
    seen_generation INTEGER NOT NULL DEFAULT 0
  ) STRICT;
  ALTER TABLE product ADD COLUMN discount_subject TEXT;
  ALTER TABLE customer ADD COLUMN customer_group_id TEXT;
  ''',
  // Crediário do cliente (limite, parâmetros e parcelas em aberto), para vender e receber sem internet.
  '''
  ALTER TABLE customer ADD COLUMN credit TEXT;
  -- Devolução que abate o crediário: o destino novo pede refazer a tabela (o SQLite não muda CHECK).
  -- As chaves estrangeiras ficam desligadas na migração e são conferidas no fim (veja _migrateTo).
  CREATE TABLE sale_return_new (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    number INTEGER NOT NULL UNIQUE CHECK (number > 0),
    code TEXT NOT NULL,
    sale_id BLOB NOT NULL,
    sale_code TEXT NOT NULL,
    destination TEXT NOT NULL CHECK (destination IN ('credit', 'agreement', 'cash', 'store_credit')),
    total_cents INTEGER NOT NULL CHECK (total_cents > 0),
    paid INTEGER NOT NULL DEFAULT 0,
    returned_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    updated_by BLOB,
    trace_id BLOB
  ) STRICT;
  INSERT INTO sale_return_new SELECT * FROM sale_return;
  DROP TABLE sale_return;
  ALTER TABLE sale_return_new RENAME TO sale_return;
  ''',
  // Cashback: o percentual do produto (para o comprovante) e a parte do cashback na devolução.
  '''
  ALTER TABLE product ADD COLUMN cashback_bp INTEGER;
  ALTER TABLE sale_return ADD COLUMN cashback_refund_cents INTEGER NOT NULL DEFAULT 0;
  ''',
  // NFC-e: a entrega do certificado e do CSC fica como veio, cifrada para a chave deste caixa.
  '''
  CREATE TABLE nfce_credential (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    credential_version TEXT NOT NULL,
    fiscal_key TEXT NOT NULL,
    valid_to TEXT NOT NULL,
    envelope TEXT NOT NULL,
    received_at TEXT NOT NULL
  ) STRICT;
  ''',
  // Profissionais da saúde (prescritores) do grupo, para a busca na receita do controlado.
  '''
  CREATE TABLE health_professional (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    name TEXT NOT NULL,
    council TEXT NOT NULL,
    registration TEXT NOT NULL,
    state TEXT NOT NULL,
    specialty TEXT,
    search TEXT NOT NULL,
    seen_generation INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX health_professional_registration_idx ON health_professional (council, state, registration);
  ''',
  // NFC-e emitida no caixa: a nota (autorizada com o protocolo, ou a assinada quando ficou pendente).
  '''
  CREATE TABLE nfce_document (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL UNIQUE CHECK (length(sale_id) = 16),
    series INTEGER NOT NULL,
    number INTEGER NOT NULL,
    access_key TEXT NOT NULL UNIQUE,
    environment INTEGER NOT NULL CHECK (environment IN (1, 2)),
    emission_type INTEGER NOT NULL CHECK (emission_type IN (1, 9)),
    status TEXT NOT NULL CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency')),
    protocol TEXT,
    status_code TEXT,
    reason TEXT,
    xml TEXT NOT NULL,
    qr_code TEXT NOT NULL,
    consult_url TEXT NOT NULL,
    emitted_at TEXT NOT NULL,
    authorized_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL,
    UNIQUE (series, number)
  ) STRICT;
  ''',
  // NFC-e cancelada (pelo caixa ou pela retaguarda): a tabela é refeita com a situação nova, com as
  // notas que já estavam nela.
  '''
  CREATE TABLE nfce_document_new (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL UNIQUE CHECK (length(sale_id) = 16),
    series INTEGER NOT NULL,
    number INTEGER NOT NULL,
    access_key TEXT NOT NULL UNIQUE,
    environment INTEGER NOT NULL CHECK (environment IN (1, 2)),
    emission_type INTEGER NOT NULL CHECK (emission_type IN (1, 9)),
    status TEXT NOT NULL CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency', 'canceled')),
    protocol TEXT,
    status_code TEXT,
    reason TEXT,
    xml TEXT NOT NULL,
    qr_code TEXT NOT NULL,
    consult_url TEXT NOT NULL,
    emitted_at TEXT NOT NULL,
    authorized_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL,
    UNIQUE (series, number)
  ) STRICT;
  INSERT INTO nfce_document_new SELECT * FROM nfce_document;
  DROP TABLE nfce_document;
  ALTER TABLE nfce_document_new RENAME TO nfce_document;
  ''',
  // Curva ABC do cliente na filial do terminal (vem com os dados do cliente).
  '''
  ALTER TABLE customer ADD COLUMN abc_curve TEXT CHECK (abc_curve IN ('A', 'B', 'C'));
  ''',
  // Unidade de medida do produto (UN, CX, KG...), que vai na NFC-e. Quem já tem produto fica com UN,
  // o que a NFC-e já levava; a central manda a unidade certa na próxima mudança do produto.
  '''
  ALTER TABLE product ADD COLUMN unit TEXT NOT NULL DEFAULT 'UN' CHECK (length(unit) BETWEEN 1 AND 6);
  ''',
  // Inscrição estadual e indicador de IE do cliente (1, 2 ou 9), para a NF-e de venda. Quem já está
  // guardado recebe na próxima descida do cliente.
  '''
  ALTER TABLE customer ADD COLUMN state_registration TEXT;
  ALTER TABLE customer ADD COLUMN ie_indicator INTEGER CHECK (ie_indicator IN (1, 2, 9));
  ''',
  // NF-e de venda (modelo 55) guardada com a NFC-e: a tabela ganha o modelo, e a numeração passa a
  // ser única por modelo e série (a série 1 da NF-e e a da NFC-e são numerações diferentes). A NF-e
  // não tem QR Code nem endereço de consulta (ficam vazios).
  '''
  CREATE TABLE nfce_document_new (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL UNIQUE CHECK (length(sale_id) = 16),
    model TEXT NOT NULL DEFAULT '65' CHECK (model IN ('55', '65')),
    series INTEGER NOT NULL,
    number INTEGER NOT NULL,
    access_key TEXT NOT NULL UNIQUE,
    environment INTEGER NOT NULL CHECK (environment IN (1, 2)),
    emission_type INTEGER NOT NULL CHECK (emission_type IN (1, 9)),
    status TEXT NOT NULL CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency', 'canceled')),
    protocol TEXT,
    status_code TEXT,
    reason TEXT,
    xml TEXT NOT NULL,
    qr_code TEXT NOT NULL,
    consult_url TEXT NOT NULL,
    emitted_at TEXT NOT NULL,
    authorized_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL,
    UNIQUE (model, series, number),
    CHECK (model = '65' OR emission_type = 1)
  ) STRICT;
  INSERT INTO nfce_document_new (id, sale_id, series, number, access_key, environment, emission_type, status, protocol,
    status_code, reason, xml, qr_code, consult_url, emitted_at, authorized_at, attempts, updated_at)
  SELECT id, sale_id, series, number, access_key, environment, emission_type, status, protocol, status_code, reason, xml,
    qr_code, consult_url, emitted_at, authorized_at, attempts, updated_at FROM nfce_document;
  DROP TABLE nfce_document;
  ALTER TABLE nfce_document_new RENAME TO nfce_document;
  ''',
  // Contingência da NF-e 55 na Sefaz Virtual (tpEmis 6 SVC-AN, 7 SVC-RS): a NFC-e continua com 1 e 9.
  '''
  CREATE TABLE nfce_document_new (
    id BLOB PRIMARY KEY CHECK (length(id) = 16),
    sale_id BLOB NOT NULL UNIQUE CHECK (length(sale_id) = 16),
    model TEXT NOT NULL DEFAULT '65' CHECK (model IN ('55', '65')),
    series INTEGER NOT NULL,
    number INTEGER NOT NULL,
    access_key TEXT NOT NULL UNIQUE,
    environment INTEGER NOT NULL CHECK (environment IN (1, 2)),
    emission_type INTEGER NOT NULL CHECK (emission_type IN (1, 6, 7, 9)),
    status TEXT NOT NULL CHECK (status IN ('authorized', 'rejected', 'pending', 'contingency', 'canceled')),
    protocol TEXT,
    status_code TEXT,
    reason TEXT,
    xml TEXT NOT NULL,
    qr_code TEXT NOT NULL,
    consult_url TEXT NOT NULL,
    emitted_at TEXT NOT NULL,
    authorized_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL,
    UNIQUE (model, series, number),
    CHECK ((model = '65' AND emission_type IN (1, 9)) OR (model = '55' AND emission_type IN (1, 6, 7)))
  ) STRICT;
  INSERT INTO nfce_document_new SELECT * FROM nfce_document;
  DROP TABLE nfce_document;
  ALTER TABLE nfce_document_new RENAME TO nfce_document;
  ''',
  // Arquivo do que sobrou de outro terminal (itens não enviados e notas fiscais), quando o caixa é
  // pareado de novo e a cópia local é refeita. Nunca é limpo e fica criptografado como o resto.
  '''
  CREATE TABLE local_archive (
    id INTEGER PRIMARY KEY,
    terminal_id TEXT,
    source TEXT NOT NULL,
    data TEXT NOT NULL,
    archived_at TEXT NOT NULL
  ) STRICT;
  ''',
];

/// Como a cópia local ficou ao ser ligada ao terminal pareado.
enum TerminalBinding {
  /// Já era deste terminal.
  same,

  /// Cópia vazia, ou de antes desta marca com itens por enviar: passa a ser deste terminal.
  adopted,

  /// Era de outro terminal: o que importava foi arquivado e a cópia foi limpa para a carga inteira.
  reset,
}

/// Resultado de [LocalDatabase.bindTerminal]: [archived] itens não enviados e notas guardados no arquivo.
typedef TerminalBindResult = ({TerminalBinding binding, int archived});

/// NFC-e (ou NF-e de venda, modelo 55) do caixa, para guardar, imprimir o DANFE e subir à central.
class LocalNfce {
  const LocalNfce({
    required this.id,
    required this.saleId,
    this.model = '65',
    required this.series,
    required this.number,
    required this.accessKey,
    required this.environment,
    required this.emissionType,
    required this.status,
    this.protocol,
    this.statusCode,
    this.reason,
    required this.xml,
    required this.qrCode,
    required this.consultUrl,
    required this.emittedAt,
    this.authorizedAt,
  });

  final String id;
  final String saleId;

  /// 65 NFC-e (cupom), 55 NF-e de venda (DANFE A4).
  final String model;
  final int series;
  final int number;
  final String accessKey;
  final int environment;
  final int emissionType;

  bool get isNfe => model == '55';

  /// authorized, rejected, pending ou contingency.
  final String status;
  final String? protocol;
  final String? statusCode;
  final String? reason;
  final String xml;
  final String qrCode;
  final String consultUrl;
  final DateTime emittedAt;
  final DateTime? authorizedAt;

  bool get authorized => status == 'authorized';

  LocalNfce copyWith({required String status, String? protocol, String? statusCode, String? reason, String? xml, DateTime? authorizedAt}) =>
      LocalNfce(
        id: id,
        saleId: saleId,
        model: model,
        series: series,
        number: number,
        accessKey: accessKey,
        environment: environment,
        emissionType: emissionType,
        status: status,
        protocol: protocol,
        statusCode: statusCode,
        reason: reason,
        xml: xml ?? this.xml,
        qrCode: qrCode,
        consultUrl: consultUrl,
        emittedAt: emittedAt,
        authorizedAt: authorizedAt,
      );

  /// Vale como DANFE: autorizada ou emitida em contingência.
  bool get printable => authorized || status == 'contingency';

  /// O que sobe para a central (item "nfce" da outbox).
  Map<String, Object?> toPayload() => {
    'id': id,
    'model': model,
    'sale_id': saleId,
    'series': series,
    'number': number,
    'access_key': accessKey,
    'environment': environment,
    'emission_type': emissionType,
    'status': status,
    'protocol': protocol,
    'status_code': statusCode,
    'reason': reason,
    'xml': xml,
    'emitted_at': emittedAt.toUtc().toIso8601String(),
    'authorized_at': authorizedAt?.toUtc().toIso8601String(),
  };
}

/// Profissional da saúde (prescritor) na cópia local.
class LocalProfessional {
  const LocalProfessional({
    required this.id,
    required this.name,
    required this.council,
    required this.registration,
    required this.state,
    this.specialty,
  });

  final String id;
  final String name;
  final String council;
  final String registration;
  final String state;
  final String? specialty;

  String get label => '$name · $council $registration/$state';
}

/// Número no conselho para comparar: sem zeros à esquerda e em maiúsculas (igual à central).
String registrationKey(String value) => value.trim().toUpperCase().replaceFirst(RegExp('^0+'), '');

/// Entrega do certificado e do CSC guardada no caixa (o conteúdo continua cifrado).
class StoredNfceCredential {
  const StoredNfceCredential({
    required this.credentialVersion,
    required this.fiscalKey,
    required this.validTo,
    required this.envelope,
    required this.receivedAt,
  });

  final String credentialVersion;
  final String fiscalKey;
  final DateTime validTo;
  final Map<String, dynamic> envelope;
  final DateTime receivedAt;
}

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
    this.authMode = 'pin',
    this.hasFace = false,
  });

  final String id;
  final int code;
  final String name;
  final bool isAdmin;
  final List<String> permissions;

  /// Limites por tipo; vazio (null) é sem teto.
  final Map<String, num?> limits;
  final String? pinHash;

  /// Forma de entrar no PDV: any, pin, face ou fingerprint.
  final String authMode;

  /// Tem rosto cadastrado neste terminal.
  final bool hasFace;

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
    this.discountSubject = const {},
    this.cashbackBp,
  });

  /// Cashback do produto em centésimos de ponto (500 = 5%), pelo motor de regras; vazio é sem regra.
  final int? cashbackBp;

  /// Desconto máximo em centésimos de ponto (750 = 7,5%); vazio é sem regra.
  final int? maxDiscountBp;
  final DateTime? maxDiscountUntil;

  /// Hierarquia do motor (família, fabricante, categorias, grupos), para os descontos automáticos.
  final Map<String, Object?> discountSubject;

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
    Database db;
    try {
      db = _openEncrypted(file.path, key);
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
      db = _openEncrypted(file.path, key);
    }
    // A migração fica fora do tratamento acima: se falhar, o banco não é posto de lado (os dados
    // continuam no arquivo) e o erro sobe, para a atualização voltar à versão anterior.
    try {
      return LocalDatabase._(db);
    } catch (_) {
      db.close();
      rethrow;
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

  void _migrate() => _migrateTo(_db, _migrations.length);

  /// Aplica as migrações até [version]. As chaves estrangeiras ficam desligadas durante a migração
  /// (como manda o SQLite para refazer tabela): o DROP da tabela antiga contaria violação nas tabelas
  /// filhas mesmo com a nova no lugar. No fim de cada migração, dentro da transação, tudo é conferido
  /// (foreign_key_check): se sobrar referência quebrada, a migração volta inteira.
  static void _migrateTo(Database db, int version) {
    final current = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (current >= version) return;
    db.execute('PRAGMA foreign_keys = OFF');
    try {
      for (var index = current; index < version; index += 1) {
        db.execute('BEGIN');
        try {
          db.execute(_migrations[index]);
          final broken = db.select('PRAGMA foreign_key_check');
          if (broken.isNotEmpty) {
            throw StateError('Migração ${index + 1} deixou referência quebrada em ${broken.first['table']}.');
          }
          db.execute('PRAGMA user_version = ${index + 1}');
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
    } finally {
      db.execute('PRAGMA foreign_keys = ON');
    }
  }

  /// Só para testes: um banco em memória parado numa versão antiga, para conferir a atualização.
  @visibleForTesting
  static Database migratedInMemory(int version) {
    final db = sqlite3.openInMemory();
    _migrateTo(db, version);
    return db;
  }

  /// Só para testes: abre (e atualiza) um banco montado pelo teste.
  @visibleForTesting
  factory LocalDatabase.fromDatabase(Database db) => LocalDatabase._(db);

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

  /// Terminal a que a cópia local pertence (null antes desta marca existir).
  String? get dataTerminalId => _state('data_terminal_id');

  /// Liga a cópia local ao terminal pareado, antes de subir ou descer qualquer coisa.
  ///
  /// Cópia de outro terminal (o caixa foi pareado de novo, por exemplo numa central nova): os itens
  /// ainda não enviados e as notas fiscais vão para o arquivo local, e todo o resto é limpo — a carga
  /// inteira refaz a cópia e nada de outra central sobe. Ficam só os ajustes do aparelho
  /// (impressora, tela). Cópia de antes desta marca: com itens por enviar, é adotada (nada se
  /// perde); sem eles, é refeita como a de outro terminal.
  TerminalBindResult bindTerminal(String terminalId, {required DateTime now}) {
    final current = dataTerminalId;
    if (current == terminalId) return (binding: TerminalBinding.same, archived: 0);
    final hasData = _db.select(
      'SELECT EXISTS (SELECT 1 FROM app_user) OR EXISTS (SELECT 1 FROM product) OR EXISTS (SELECT 1 FROM sale) '
      'OR EXISTS (SELECT 1 FROM cash_session) OR EXISTS (SELECT 1 FROM nfce_document) '
      "OR EXISTS (SELECT 1 FROM outbox WHERE kind <> 'log') AS v",
    ).first['v'] == 1;
    final pending = _db.select("SELECT count(*) AS n FROM outbox WHERE sent_at IS NULL AND kind <> 'log'").first['n'] as int;
    if (!hasData || (current == null && pending > 0)) {
      _setState('data_terminal_id', terminalId);
      return (binding: TerminalBinding.adopted, archived: 0);
    }
    var archived = 0;
    _transaction(() {
      // A limpeza passa por tabelas ligadas entre si: as chaves são conferidas no fim.
      _db.execute('PRAGMA defer_foreign_keys = ON');
      final at = now.toUtc().toIso8601String();
      void archive(String source, String sql) {
        for (final row in _db.select(sql)) {
          final data = <String, Object?>{
            for (final column in row.keys) column: switch (row[column]) { final Uint8List bytes => base64Encode(bytes), final other => other },
          };
          _db.execute(
            'INSERT INTO local_archive (terminal_id, source, data, archived_at) VALUES (?, ?, ?, ?)',
            [current, source, jsonEncode(data), at],
          );
          archived += 1;
        }
      }

      archive('outbox', "SELECT * FROM outbox WHERE sent_at IS NULL AND kind <> 'log' ORDER BY sequence");
      archive('nfce_document', 'SELECT * FROM nfce_document ORDER BY emitted_at');
      final tables = _db
          .select("SELECT name FROM pragma_table_list WHERE schema = 'main' AND type IN ('table', 'virtual')")
          .map((row) => row['name'] as String)
          .where((name) => !name.startsWith('sqlite_') && name != 'local_archive' && name != 'sync_state');
      for (final table in tables) {
        _db.execute('DELETE FROM "$table"');
      }
      // Fica só o que é do aparelho (impressora, tela).
      _db.execute("DELETE FROM sync_state WHERE key NOT LIKE 'setting:%'");
      _setState('data_terminal_id', terminalId);
    });
    return (binding: TerminalBinding.reset, archived: archived);
  }

  /// Quantos registros o arquivo local guarda (de terminais anteriores).
  int get archivedCount => _db.select('SELECT count(*) AS n FROM local_archive').first['n'] as int;

  /// Registros do arquivo local, do mais antigo ao mais novo (para o suporte e os testes).
  List<({String? terminalId, String source, String data, String archivedAt})> archivedRows() => [
    for (final row in _db.select('SELECT terminal_id, source, data, archived_at FROM local_archive ORDER BY id'))
      (
        terminalId: row['terminal_id'] as String?,
        source: row['source'] as String,
        data: row['data'] as String,
        archivedAt: row['archived_at'] as String,
      ),
  ];

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
      for (final table in ['product', 'app_user', 'fiscal', 'health_professional', 'discount_rule']) {
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
            'INSERT INTO app_user (id, code, name, is_admin, roles, permissions, limits, pin_hash, auth_mode, face_model, face_template, seen_generation) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET code = excluded.code, '
            'name = excluded.name, is_admin = excluded.is_admin, roles = excluded.roles, '
            'permissions = excluded.permissions, limits = excluded.limits, pin_hash = excluded.pin_hash, auth_mode = excluded.auth_mode, '
            'face_model = excluded.face_model, face_template = excluded.face_template, '
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
              const {'any', 'pin', 'face', 'fingerprint'}.contains(data['auth_mode']) ? data['auth_mode'] : 'pin',
              ..._faceColumns(data['face']),
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
      case 'health_professional':
        if (data == null) {
          _db.execute('DELETE FROM health_professional WHERE id = ?', [id]);
        } else {
          _upsertProfessional(id, data, generation);
        }
      case 'discount_rule':
        if (data == null) {
          _db.execute('DELETE FROM discount_rule WHERE id = ?', [id]);
        } else {
          _db.execute(
            'INSERT INTO discount_rule (id, data, seen_generation) VALUES (?, ?, ?) '
            'ON CONFLICT (id) DO UPDATE SET data = excluded.data, seen_generation = excluded.seen_generation',
            [id, jsonEncode(data), generation],
          );
        }
      default:
        // Tipo novo de uma versão mais nova da central: fica para a próxima atualização do PDV.
        break;
    }
  }

  static String _unit(Object? value) {
    final text = value is String ? value.trim().toUpperCase() : '';
    return RegExp(r'^[A-Z]{1,6}$').hasMatch(text) ? text : 'UN';
  }

  void _upsertProduct(Uint8List id, Map<String, dynamic> data, int generation) {
    _db.execute(
      'INSERT INTO product (id, code, name, manufacturer, active_ingredient, controlled_class, ms_registration, '
      'ncm, cest, status, price_cents, fraction_milli, batch_required, seen_generation, max_discount_bp, max_discount_until, '
      'discount_subject, cashback_bp, unit) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      'unit = excluded.unit, '
      'max_discount_bp = excluded.max_discount_bp, max_discount_until = excluded.max_discount_until, '
      'cashback_bp = excluded.cashback_bp, '
      'discount_subject = excluded.discount_subject, '
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
        data['discount_subject'] is Map ? jsonEncode(data['discount_subject']) : null,
        data['cashback'] == null ? null : ((data['cashback'] as num) * 100).round(),
        // Central antiga (sem a unidade) ou sigla fora do tamanho: UN, como a NFC-e já levava.
        _unit(data['unit']),
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

  void _upsertProfessional(Uint8List id, Map<String, dynamic> data, int generation) {
    final name = data['name'] as String;
    _db.execute(
      'INSERT INTO health_professional (id, name, council, registration, state, specialty, search, seen_generation) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET name = excluded.name, council = excluded.council, '
      'registration = excluded.registration, state = excluded.state, specialty = excluded.specialty, '
      'search = excluded.search, seen_generation = excluded.seen_generation',
      [id, name, data['council'], data['registration'], data['state'], data['specialty'], foldText(name), generation],
    );
  }

  LocalProfessional _professional(Row row) => LocalProfessional(
    id: uuidText(row['id'] as List<int>),
    name: row['name'] as String,
    council: row['council'] as String,
    registration: row['registration'] as String,
    state: row['state'] as String,
    specialty: row['specialty'] as String?,
  );

  /// Busca do prescritor na receita: pelo nome (sem acento) ou pelo número no conselho.
  List<LocalProfessional> searchProfessionals(String term, {int limit = 8}) {
    final text = term.trim();
    if (text.length < 2) return const [];
    final rows = _db.select(
      'SELECT * FROM health_professional WHERE search LIKE ? OR ltrim(upper(registration), \'0\') = ? '
      'ORDER BY name LIMIT ?',
      ['%${foldText(text)}%', registrationKey(text), limit],
    );
    return [for (final row in rows) _professional(row)];
  }

  /// O profissional com este conselho, número e UF, se já estiver na cópia local.
  LocalProfessional? professionalByRegistration(String council, String registration, String state) {
    for (final row in _db.select(
      'SELECT * FROM health_professional WHERE council = ? AND state = ?',
      [council, state.trim().toUpperCase()],
    )) {
      if (registrationKey(row['registration'] as String) == registrationKey(registration)) return _professional(row);
    }
    return null;
  }

  /// Cadastro rápido no caixa: entra na cópia local e sobe pela outbox, na mesma transação.
  LocalProfessional saveProfessional({
    required String name,
    required String council,
    required String registration,
    required String state,
    required DateTime now,
    String? createdBy,
  }) => _transaction(() {
    final professional = LocalProfessional(
      id: const Uuid().v7(),
      name: name.trim().replaceAll(RegExp(r'\s+'), ' '),
      council: council,
      registration: registration.trim(),
      state: state.trim().toUpperCase(),
    );
    _upsertProfessional(uuidBytes(professional.id), {
      'name': professional.name,
      'council': professional.council,
      'registration': professional.registration,
      'state': professional.state,
      'specialty': null,
    }, syncState.generation);
    enqueue('health_professional', {
      'id': professional.id,
      'name': professional.name,
      'council': professional.council,
      'registration': professional.registration,
      'state': professional.state,
      // Quem cadastrou (ou o supervisor que liberou): a central confere a permissão.
      'created_by': ?createdBy,
    }, now: now);
    return professional;
  });

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
  /// A venda (ou a NFC-e dela) ainda está na fila para a central.
  bool outboxHasSale(String saleId) =>
      (_db.select(
            "SELECT count(*) AS n FROM outbox WHERE sent_at IS NULL AND kind IN ('sale', 'nfce') "
            r"AND (json_extract(payload, '$.id') = ? OR json_extract(payload, '$.sale_id') = ?)",
            [saleId, saleId],
          ).first['n'] as int) >
      0;

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
      'customer_group_id', 'credit', 'abc_curve', 'state_registration', 'ie_indicator',
    ];
    final search = normalizeSearch('${data['name'] ?? ''} ${data['trade_name'] ?? ''}');
    _db.execute(
      'INSERT INTO customer (id, ${columns.join(', ')}, search_text, saved_at) '
      'VALUES (?, ${List.filled(columns.length, '?').join(', ')}, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      '${columns.map((c) => '$c = excluded.$c').join(', ')}, search_text = excluded.search_text, saved_at = excluded.saved_at',
      [
        id,
        for (final c in columns)
          c == 'agreements'
              ? jsonEncode(data[c] ?? const [])
              : c == 'credit'
              ? (data[c] == null ? null : jsonEncode(data[c]))
              : data[c],
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
    row['credit'] = row['credit'] == null ? null : jsonDecode(row['credit']! as String);
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
    // Se sobrou alguém antigo com o mesmo código, vale quem chegou por último na cópia.
    final rows = _db.select('SELECT * FROM app_user WHERE code = ? ORDER BY seen_generation DESC, rowid DESC LIMIT 1', [code]);
    if (rows.isEmpty) return null;
    return _user(rows.first);
  }

  /// Modelo e código do rosto que vieram da central; fora do formato, sem rosto.
  static List<Object?> _faceColumns(Object? face) {
    if (face is! Map) return const [null, null];
    final model = face['model'];
    final template = face['template'];
    if (model is! String || template is! String) return const [null, null];
    try {
      final bytes = base64.decode(template);
      return bytes.length == 512 ? [model, bytes] : const [null, null];
    } on FormatException {
      return const [null, null];
    }
  }

  /// Pessoas com rosto cadastrado neste modelo, com o código, para comparar sem internet.
  List<({LocalUser candidate, List<double> template})> faceCandidates(String model) => [
    for (final row in _db.select('SELECT * FROM app_user WHERE face_model = ? AND face_template IS NOT NULL', [model]))
      (candidate: _user(row), template: templateFromBytes(Uint8List.fromList(row['face_template'] as List<int>))),
  ];

  /// Rosto cadastrado neste terminal: vale aqui na hora e sobe para a central (outbox), na mesma
  /// transação.
  void saveFaceEnrollment(Map<String, Object?> payload, {required Uint8List template, required DateTime now}) => _transaction(() {
    _db.execute(
      'UPDATE app_user SET face_model = ?, face_template = ? WHERE id = ?',
      [payload['model'], template, uuidBytes(payload['user_id']! as String)],
    );
    enqueue('face_enrollment', payload, now: now);
  });

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
    authMode: row['auth_mode'] as String? ?? 'pin',
    hasFace: row['face_template'] != null,
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
      'unit': row['unit'],
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
    cashbackBp: row['cashback_bp'] as int?,
    maxDiscountUntil: DateTime.tryParse(row['max_discount_until'] as String? ?? ''),
    discountSubject: _subject(row['discount_subject'] as String?, uuidText(row['id'] as List<int>)),
  );

  /// Onde o produto está na hierarquia do motor; sem a informação (carga antiga), só o próprio id.
  static Map<String, Object?> _subject(String? json, String productId) {
    if (json == null) return {'id': productId};
    try {
      return (jsonDecode(json) as Map).cast<String, Object?>();
    } on FormatException {
      return {'id': productId};
    }
  }

  /// Regras de desconto que vieram da central (o cálculo filtra a validade e a filial).
  List<Map<String, dynamic>> get discountRules => [
    for (final row in _db.select('SELECT data FROM discount_rule'))
      (jsonDecode(row['data'] as String) as Map).cast<String, dynamic>(),
  ];

  /// Dados da filial e da empresa (para o comprovante) e o último número que a central conhece.
  Map<String, dynamic>? get fiscal {
    final rows = _db.select('SELECT data FROM fiscal LIMIT 1');
    return rows.isEmpty ? null : jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
  }

  StoredNfceCredential? get nfceCredential {
    final rows = _db.select('SELECT * FROM nfce_credential WHERE id = 1');
    if (rows.isEmpty) return null;
    final row = rows.first;
    return StoredNfceCredential(
      credentialVersion: row['credential_version'] as String,
      fiscalKey: row['fiscal_key'] as String,
      validTo: DateTime.parse(row['valid_to'] as String),
      envelope: (jsonDecode(row['envelope'] as String) as Map).cast<String, dynamic>(),
      receivedAt: DateTime.parse(row['received_at'] as String),
    );
  }

  void saveNfceCredential(StoredNfceCredential credential) {
    _db.execute(
      'INSERT INTO nfce_credential (id, credential_version, fiscal_key, valid_to, envelope, received_at) '
      'VALUES (1, ?, ?, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET credential_version = excluded.credential_version, '
      'fiscal_key = excluded.fiscal_key, valid_to = excluded.valid_to, envelope = excluded.envelope, '
      'received_at = excluded.received_at',
      [
        credential.credentialVersion,
        credential.fiscalKey,
        credential.validTo.toUtc().toIso8601String(),
        jsonEncode(credential.envelope),
        credential.receivedAt.toUtc().toIso8601String(),
      ],
    );
  }

  /// Série e próximo número da NFC-e deste caixa: depois do maior entre o inicial, o que a
  /// central conhece e o que este caixa já usou. Null sem série do modelo 65.
  ({int series, int number})? nextNfceNumber() => nextFiscalNumber('65');

  /// Série e próximo número do modelo (65 NFC-e, 55 NF-e) neste caixa. Null sem série do modelo.
  ({int series, int number})? nextFiscalNumber(String model) {
    final rows = _db.select(
      'SELECT series, initial_number, central_last_used_number, local_last_used_number FROM fiscal_series '
      'WHERE model = ? AND active = 1 LIMIT 1',
      [model],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final used = [
      (row['initial_number'] as int) - 1,
      (row['central_last_used_number'] as int?) ?? 0,
      (row['local_last_used_number'] as int?) ?? 0,
    ].reduce(max);
    return (series: row['series'] as int, number: used + 1);
  }

  /// Guarda a nota, gasta o número da série e põe a nota na outbox, na mesma transação.
  void saveNfce(LocalNfce nfce, {required DateTime now}) => _transaction(() {
    final stamp = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO nfce_document (id, sale_id, model, series, number, access_key, environment, emission_type, status, protocol, '
      'status_code, reason, xml, qr_code, consult_url, emitted_at, authorized_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuidBytes(nfce.id), uuidBytes(nfce.saleId), nfce.model, nfce.series, nfce.number, nfce.accessKey, nfce.environment,
        nfce.emissionType, nfce.status, nfce.protocol, nfce.statusCode, nfce.reason, nfce.xml, nfce.qrCode,
        nfce.consultUrl, nfce.emittedAt.toUtc().toIso8601String(), nfce.authorizedAt?.toUtc().toIso8601String(), stamp,
      ],
    );
    _db.execute(
      'UPDATE fiscal_series SET local_last_used_number = max(COALESCE(local_last_used_number, 0), ?) '
      'WHERE model = ? AND series = ?',
      [nfce.number, nfce.model, nfce.series],
    );
    enqueue('nfce', nfce.toPayload(), now: now);
  });

  /// NFC-e de uma venda deste caixa, se houver.
  LocalNfce? nfceOfSale(String saleId) {
    final rows = _db.select('SELECT * FROM nfce_document WHERE sale_id = ?', [uuidBytes(saleId)]);
    return rows.isEmpty ? null : _nfce(rows.first);
  }

  /// Notas a transmitir: em contingência ou pendentes (sem resposta), as mais antigas primeiro.
  List<LocalNfce> nfceToTransmit({int limit = 20}) => [
    for (final row in _db.select(
      "SELECT * FROM nfce_document WHERE status IN ('contingency', 'pending') ORDER BY emitted_at LIMIT ?",
      [limit],
    ))
      _nfce(row),
  ];

  /// Notas em contingência ainda não transmitidas: quantas e desde quando (a mais antiga).
  ({int count, DateTime? oldest}) nfceContingency() {
    final row = _db.select("SELECT count(*) AS n, min(emitted_at) AS oldest FROM nfce_document WHERE status = 'contingency'").first;
    final oldest = row['oldest'] as String?;
    return (count: row['n'] as int, oldest: oldest == null ? null : DateTime.parse(oldest));
  }

  /// Resultado da transmissão: muda a situação (e o XML, quando autorizada) e sobe de novo pela
  /// outbox, com o mesmo id (a central atualiza a nota).
  void updateNfce(LocalNfce nfce, {required DateTime now}) => _transaction(() {
    _db.execute(
      'UPDATE nfce_document SET status = ?, protocol = ?, status_code = ?, reason = ?, xml = ?, authorized_at = ?, '
      'attempts = attempts + 1, updated_at = ? WHERE id = ?',
      [
        nfce.status, nfce.protocol, nfce.statusCode, nfce.reason, nfce.xml, nfce.authorizedAt?.toUtc().toIso8601String(),
        now.toUtc().toIso8601String(), uuidBytes(nfce.id),
      ],
    );
    enqueue('nfce', nfce.toPayload(), now: now);
  });

  /// Tentativa sem resposta: só conta, sem subir nada.
  void countNfceAttempt(String id, {required DateTime now}) => _db.execute(
    'UPDATE nfce_document SET attempts = attempts + 1, updated_at = ? WHERE id = ?',
    [now.toUtc().toIso8601String(), uuidBytes(id)],
  );

  LocalNfce _nfce(Row row) {
    final saleId = uuidText(row['sale_id'] as List<int>);
    DateTime? when(Object? value) => value == null ? null : DateTime.parse(value as String);
    return LocalNfce(
      id: uuidText(row['id'] as List<int>),
      saleId: saleId,
      model: row['model'] as String,
      series: row['series'] as int,
      number: row['number'] as int,
      accessKey: row['access_key'] as String,
      environment: row['environment'] as int,
      emissionType: row['emission_type'] as int,
      status: row['status'] as String,
      protocol: row['protocol'] as String?,
      statusCode: row['status_code'] as String?,
      reason: row['reason'] as String?,
      xml: row['xml'] as String,
      qrCode: row['qr_code'] as String,
      consultUrl: row['consult_url'] as String,
      emittedAt: DateTime.parse(row['emitted_at'] as String),
      authorizedAt: when(row['authorized_at']),
    );
  }

  /// Dados fiscais do produto para a nota: NCM, CEST, GTIN do código principal e a tributação
  /// em vigor no dia (a mais recente que já começou).
  ({String? ncm, String? cest, String? gtin, String unit, Map<String, dynamic>? tax})? nfceProductData(String productId, DateTime day) {
    final id = uuidBytes(productId);
    final rows = _db.select('SELECT ncm, cest, unit FROM product WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    String two(int value) => value.toString().padLeft(2, '0');
    final today = '${day.year}-${two(day.month)}-${two(day.day)}';
    final tax = _db.select(
      'SELECT data FROM product_tax WHERE product_id = ? AND valid_from <= ? ORDER BY valid_from DESC LIMIT 1',
      [id, today],
    );
    final barcode = _db.select(
      'SELECT code FROM product_barcode WHERE product_id = ? ORDER BY is_primary DESC, code LIMIT 1',
      [id],
    );
    final gtin = barcode.isEmpty ? null : barcode.first['code'] as String;
    return (
      ncm: rows.first['ncm'] as String?,
      cest: rows.first['cest'] as String?,
      unit: rows.first['unit'] as String,
      // Só GTIN de verdade (8, 12, 13 ou 14 dígitos); código interno vai como "SEM GTIN".
      gtin: gtin != null && RegExp(r'^(\d{8}|\d{12,14})$').hasMatch(gtin) ? gtin : null,
      tax: tax.isEmpty ? null : (jsonDecode(tax.first['data'] as String) as Map).cast<String, dynamic>(),
    );
  }

  /// NFC-e desligada na filial: o caixa não guarda mais o certificado.
  void clearNfceCredential() => _db.execute('DELETE FROM nfce_credential');

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

  /// Prazo de devolução da filial, em dias.
  int get returnDays => (fiscal?['return_days'] as num?)?.toInt() ?? 7;

  /// Próximo número de devolução deste terminal (continua do que a central conhece).
  int get nextReturnNumber {
    final local = _db.select('SELECT COALESCE(max(number), 0) AS n FROM sale_return').first['n'] as int;
    final central = (fiscal?['last_return_number'] as num?)?.toInt() ?? 0;
    return (local > central ? local : central) + 1;
  }

  /// Venda deste terminal para devolver (sem internet), no mesmo formato que a central manda.
  Map<String, dynamic>? localSaleForReturn(String code, {required DateTime now}) {
    final sales = _db.select('SELECT * FROM sale WHERE code = ? LIMIT 1', [code.trim()]);
    if (sales.isEmpty) return null;
    final sale = sales.first;
    final saleId = sale['id'] as List<int>;
    final soldAt = DateTime.parse(sale['sold_at'] as String).toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final saleDay = DateTime(soldAt.year, soldAt.month, soldAt.day);
    final items = _db.select(
      'SELECT i.*, p.controlled_class, '
      'COALESCE((SELECT SUM(r.quantity_milli) FROM sale_return_item r WHERE r.sale_item_id = i.id), 0) AS returned_milli, '
      'COALESCE((SELECT SUM(r.amount_cents) FROM sale_return_item r WHERE r.sale_item_id = i.id), 0) AS returned_cents '
      'FROM sale_item i LEFT JOIN product p ON p.id = i.product_id WHERE i.sale_id = ? ORDER BY i.line',
      [saleId],
    );
    return {
      'id': uuidText(saleId),
      'code': sale['code'],
      'sold_at': sale['sold_at'],
      'total': (sale['total_cents'] as int) / 100,
      'cashback_used': (_db.select(
            "SELECT COALESCE(SUM(amount_cents), 0) AS c FROM sale_payment WHERE sale_id = ? AND method = 'cashback'", [saleId],
          ).first['c'] as int) / 100,
      'returned_total': (_db.select('SELECT COALESCE(SUM(total_cents), 0) AS c FROM sale_return WHERE sale_id = ?', [saleId]).first['c'] as int) / 100,
      'cashback_refunded':
          (_db.select('SELECT COALESCE(SUM(cashback_refund_cents), 0) AS c FROM sale_return WHERE sale_id = ?', [saleId]).first['c'] as int) / 100,
      'customer_id': sale['customer_id'] == null ? null : uuidText(sale['customer_id'] as List<int>),
      'customer_name': null,
      'late': today.difference(saleDay).inDays > returnDays,
      'return_days': returnDays,
      'has_agreement': _db.select("SELECT 1 FROM sale_payment WHERE sale_id = ? AND method = 'agreement' LIMIT 1", [saleId]).isNotEmpty,
      'has_store_credit': _db.select("SELECT 1 FROM sale_payment WHERE sale_id = ? AND method = 'store_credit' LIMIT 1", [saleId]).isNotEmpty,
      'items': [
        for (final item in items)
          {
            'id': uuidText(item['id'] as List<int>),
            'line': item['line'],
            'product_id': uuidText(item['product_id'] as List<int>),
            'product_code': item['product_code'],
            'product_name': item['product_name'],
            'quantity': (item['quantity_milli'] as int) / 1000,
            'total': (item['total_cents'] as int) / 100,
            'returned_quantity': (item['returned_milli'] as int) / 1000,
            'returned_amount': (item['returned_cents'] as int) / 100,
            'controlled': item['controlled_class'] != null,
          },
      ],
    };
  }

  /// Grava a devolução e põe na outbox, na mesma transação.
  void saveReturn(
    Map<String, Object?> payload, {
    required String code,
    required String saleCode,
    required DateTime now,
    int cashbackRefundCents = 0,
  }) => _transaction(() {
    final at = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO sale_return (id, number, code, sale_id, sale_code, destination, total_cents, returned_at, created_at, updated_at, '
      'cashback_refund_cents) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuidBytes(payload['id']! as String), payload['number'], code, uuidBytes(payload['sale_id']! as String), saleCode,
        payload['destination'], toCents(payload['total'])!, payload['returned_at'], at, at, cashbackRefundCents,
      ],
    );
    for (final item in (payload['items']! as List).cast<Map<String, Object?>>()) {
      _db.execute(
        'INSERT INTO sale_return_item (id, sale_return_id, sale_item_id, quantity_milli, amount_cents, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          uuidBytes(item['id']! as String), uuidBytes(payload['id']! as String), uuidBytes(item['sale_item_id']! as String),
          ((item['quantity']! as num) * 1000).round(), toCents(item['amount'])!, at, at,
        ],
      );
    }
    enqueue('sale_return', payload, now: now);
  });

  /// Devolução deste terminal em dinheiro ainda não paga (para a sangria, sem internet).
  Map<String, dynamic>? localCashReturn(String code) {
    final rows = _db.select(
      "SELECT * FROM sale_return WHERE code = ? AND destination = 'cash' AND paid = 0 LIMIT 1",
      [code.trim().toUpperCase()],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'id': uuidText(row['id'] as List<int>),
      'code': row['code'],
      // O que vai para o cliente: o total sem a parte que voltou como cashback.
      'total': ((row['total_cents'] as int) - (row['cashback_refund_cents'] as int)) / 100,
      'sale_code': row['sale_code'],
    };
  }

  /// Crédito de devolução feito neste terminal, com o que as vendas daqui já usaram (para quando não há internet).
  Map<String, dynamic>? localReturnCredit(String code) {
    final rows = _db.select(
      "SELECT r.*, COALESCE((SELECT SUM(p.amount_cents) FROM sale_payment p WHERE p.return_id = r.id AND p.method = 'return_credit'), 0) AS used "
      "FROM sale_return r WHERE r.code = ? AND r.destination = 'credit' LIMIT 1",
      [code.trim().toUpperCase()],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final total = (row['total_cents'] as int) - (row['cashback_refund_cents'] as int);
    final used = row['used'] as int;
    return {
      'id': uuidText(row['id'] as List<int>),
      'code': row['code'],
      'total': total / 100,
      'used': used / 100,
      'balance': (total - used) / 100,
    };
  }

  /// Quanto deste crédito as vendas daqui ainda não enviadas usaram (a central ainda não conhece).
  int unsentReturnCreditCents(String returnId) {
    var cents = 0;
    for (final row in _db.select("SELECT payload FROM outbox WHERE sent_at IS NULL AND kind = 'sale'")) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      for (final payment in (payload['payments'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        if (payment['method'] == 'return_credit' && payment['return_id'] == returnId) {
          cents += ((payment['amount'] as num) * 100).round();
        }
      }
    }
    return cents;
  }

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
            'return_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              uuidBytes(payment['id']! as String),
              uuidBytes(payload['id']! as String),
              payment['method'],
              cents(payment['amount']),
              toCents(payment['change']) ?? 0,
              payment['card_brand'],
              payment['authorization_code'],
              payment['return_id'] == null ? null : uuidBytes(payment['return_id']! as String),
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
      "- COALESCE((SELECT SUM(amount_cents) FROM cash_movement WHERE cash_session_id = ? AND kind = 'withdrawal'), 0) "
      r"+ COALESCE((SELECT SUM(CAST(round(json_extract(payload, '$.amount') * 100) AS INTEGER)) FROM outbox "
      r"WHERE kind = 'credit_payment' AND json_extract(payload, '$.cash_session_id') = ? AND json_extract(payload, '$.method') = 'cash'), 0) AS cents",
      [id, id, id, id, sessionId],
    ).first;
    return row['cents'] as int? ?? 0;
  }

  /// Clientes com crediário guardados neste terminal (quem deve desce para toda a rede).
  List<({String id, String name, int code})> localCreditCustomers(String query) {
    final words = normalizeSearch(query.trim()).split(' ').where((word) => word.isNotEmpty).toList();
    final rows = _db.select(
      'SELECT id, name, code FROM customer WHERE credit IS NOT NULL '
      "${words.map((_) => "AND (search_text LIKE ? ESCAPE '\\' OR CAST(code AS TEXT) = ?) ").join()}"
      'ORDER BY name, id LIMIT 30',
      [
        for (final word in words) ...[
          '%${word.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%',
          word,
        ],
      ],
    );
    return [for (final row in rows) (id: uuidText(row['id'] as List<int>), name: row['name'] as String, code: row['code'] as int)];
  }

  /// Vendas no convênio deste cliente que a central ainda não devolveu no "usado": na fila, ou já
  /// aplicadas depois da última vez que o cliente desceu. Devoluções não entram (fica mais rígido
  /// até a central devolver o cliente atualizado).
  int pendingAgreementCents(String customerId, String agreementId) {
    final saved = _db.select('SELECT saved_at FROM customer WHERE id = ?', [uuidBytes(customerId)]);
    final savedAt = saved.isEmpty ? '' : saved.first['saved_at'] as String;
    var cents = 0;
    final rows = _db.select(
      "SELECT payload FROM outbox WHERE kind = 'sale' AND (sent_at IS NULL OR (sent_at > ? AND result = 'applied'))",
      [savedAt],
    );
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      if (payload['customer_id'] != customerId) continue;
      for (final payment in (payload['payments'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        if (payment['method'] == 'agreement' && payment['agreement_id'] == agreementId) {
          cents += ((payment['amount'] as num) * 100).round();
        }
      }
    }
    return cents;
  }

  /// Recebimento do crediário: só a outbox (a central abate e devolve o cliente atualizado).
  void saveCreditPayment(Map<String, Object?> payload, {required DateTime now}) => enqueue('credit_payment', payload, now: now);

  /// O que mexe no crediário do cliente e a central ainda não devolveu: vendas, recebimentos e
  /// devoluções ainda na fila, ou já aplicados depois da última vez que o cliente desceu.
  List<Map<String, dynamic>> pendingCreditEvents(String customerId) {
    final saved = _db.select('SELECT saved_at FROM customer WHERE id = ?', [uuidBytes(customerId)]);
    final savedAt = saved.isEmpty ? '' : saved.first['saved_at'] as String;
    final events = <Map<String, dynamic>>[];
    final rows = _db.select(
      "SELECT kind, payload FROM outbox WHERE kind IN ('sale', 'credit_payment', 'sale_return') "
      "AND (sent_at IS NULL OR (sent_at > ? AND result = 'applied')) ORDER BY sequence",
      [savedAt],
    );
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      switch (row['kind']) {
        case 'sale' when payload['customer_id'] == customerId:
          for (final payment in (payload['payments'] as List? ?? const []).cast<Map<String, dynamic>>()) {
            if (payment['method'] == 'store_credit') {
              events.add({'kind': 'sale', 'at': payload['sold_at'], 'id': payload['id'], 'installments': payment['installments']});
            }
          }
        case 'credit_payment' when payload['customer_id'] == customerId:
          events.add({'kind': 'payment', 'at': payload['received_at'], 'amount': payload['amount']});
        case 'sale_return' when payload['destination'] == 'store_credit':
          final sale = _db.select('SELECT customer_id FROM sale WHERE id = ?', [uuidBytes(payload['sale_id'] as String)]);
          final owner = sale.isEmpty || sale.first['customer_id'] == null ? null : uuidText(sale.first['customer_id'] as List<int>);
          if (owner == customerId) events.add({'kind': 'payment', 'at': payload['returned_at'], 'amount': payload['total']});
      }
    }
    return events;
  }

  /// Sangria ou suprimento: grava aqui e põe na outbox, na mesma transação.
  String recordCashMovement({
    required String sessionId,
    required String kind,
    required int amountCents,
    required String reason,
    required String operatorId,
    String? releasedBy,
    String? returnId,
    required DateTime now,
  }) => _transaction(() {
    final id = const Uuid().v7();
    if (returnId != null) {
      _db.execute('UPDATE sale_return SET paid = 1, updated_at = ? WHERE id = ?', [now.toUtc().toIso8601String(), uuidBytes(returnId)]);
    }
    final at = now.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO cash_movement (id, cash_session_id, kind, amount_cents, reason, operator_id, released_by, moved_at, '
      'created_at, updated_at, return_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuidBytes(id), uuidBytes(sessionId), kind, amountCents, reason, uuidBytes(operatorId),
        releasedBy == null ? null : uuidBytes(releasedBy), at, at, at, returnId == null ? null : uuidBytes(returnId),
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
      'return_id': ?returnId,
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
