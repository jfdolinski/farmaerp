import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/core/secret_store.dart';
import 'package:farmaerp_pdv/fiscal/nfce_credentials.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

// Entrega de referência gerada pela API (apps/api/src/terminals/credential-envelope.ts), só de teste.
final _fixture = jsonDecode(File('test/fixtures/fiscal/entrega-certificado.json').readAsStringSync()) as Map<String, dynamic>;
final _terminalId = _fixture['terminalId'] as String;
final _version = _fixture['credentialVersion'] as String;
final _envelope = (_fixture['envelope'] as Map).cast<String, dynamic>();

class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  String get kind => 'system';
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Api implements TerminalApi {
  final registered = <(String, String)>[];
  int deliveries = 0;
  Object? failure;

  @override
  Future<void> registerFiscalKey({required String accessToken, required String publicKey, required String signature}) async {
    registered.add((publicKey, signature));
  }

  @override
  Future<Map<String, dynamic>> nfceCredentials({required String accessToken}) async {
    if (failure != null) throw failure!;
    deliveries += 1;
    return {'credentialVersion': _version, 'validTo': '2030-01-01T00:00:00Z', 'envelope': _envelope};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalDatabase _database({required bool enabled, String? version}) {
  final raw = LocalDatabase.migratedInMemory(14);
  raw.execute('INSERT INTO fiscal (id, data, seen_generation) VALUES (zeroblob(16), ?, 1)', [
    jsonEncode({
      'branch': {'name': 'Filial'},
      'nfce': {'enabled': enabled, 'environment': 2, 'contingency_hours': 24, 'credential_version': enabled ? (version ?? _version) : null},
    }),
  ]);
  final database = LocalDatabase.fromDatabase(raw);
  _raw[database] = raw;
  addTearDown(database.close);
  return database;
}

final _raw = Expando<Database>();

/// Nova descida dos dados fiscais (o pull grava o JSON inteiro de novo).
void _setFiscal(LocalDatabase database, Map<String, dynamic> nfce) {
  _raw[database]!.execute('UPDATE fiscal SET data = ?', [jsonEncode({'branch': {'name': 'Filial'}, 'nfce': nfce})]);
}

Future<String> _sign(String message) async => 'assinatura:$message';

void main() {
  final seed = _fixture['seed'] as String;

  test('a chave do caixa abre a entrega da central; outro terminal, versão ou chave não', () async {
    final key = await FiscalKey.fromSeed(base64Url.decode(base64Url.normalize(seed)));
    expect(key.publicKey, _fixture['publicKey']);
    final opened = NfceCredentials.parse(await key.open(_envelope, envelopeContext(_terminalId, _version)));
    expect(opened.cscId, '000001');
    expect(opened.credentialVersion, _version);
    expect(opened.privateKeyPem, File('test/fixtures/fiscal/test-key.pem').readAsStringSync());
    expect(opened.certificatePem, contains('BEGIN CERTIFICATE'));

    Future<String?> codeOf(Future<Object?> Function() call) async {
      try {
        await call();
        return null;
      } on NfceCredentialException catch (error) {
        return error.code;
      }
    }

    expect(await codeOf(() => key.open(_envelope, envelopeContext('outro-terminal', _version))), 'FA732');
    expect(await codeOf(() => key.open(_envelope, envelopeContext(_terminalId, 'outra:versao'))), 'FA732');
    final other = await FiscalKey.fromSeed(List.filled(32, 7));
    expect(await codeOf(() => other.open(_envelope, envelopeContext(_terminalId, _version))), 'FA732');
    final tampered = {..._envelope, 'data': 'A${(_envelope['data'] as String).substring(1)}'};
    expect(await codeOf(() => key.open(tampered, envelopeContext(_terminalId, _version))), 'FA732');
  });

  test('filial ligada: registra a chave assinada, recebe uma vez e guarda cifrado', () async {
    final store = _Store()..values['terminal_fiscal_seed'] = seed;
    final api = _Api();
    final database = _database(enabled: true);
    final service = NfceCredentialService(api: api, database: database, store: store, clock: () => DateTime.utc(2026, 11, 26));
    expect(service.readiness, NfceReadiness.waiting);
    expect(nfceStatusText(database, DateTime.utc(2026, 11, 26)), 'NFC-e (homologação): aguardando o certificado');

    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(api.registered, [(_fixture['publicKey'], 'assinatura:${fiscalKeyMessage(_terminalId, _fixture['publicKey'] as String)}')]);
    expect(api.deliveries, 1);
    expect(service.readiness, NfceReadiness.ready);
    expect(service.lastError, isNull);
    expect(nfceStatusText(database, DateTime.utc(2026, 11, 26)), 'NFC-e (homologação): pronta');
    // O banco local guarda a entrega como veio: o CSC não aparece aberto.
    expect(jsonEncode(database.nfceCredential!.envelope), isNot(contains('CSC-DE-TESTE')));
    expect((await service.credentials(terminalId: _terminalId))!.csc, 'CSC-DE-TESTE-0000000000000000000001');

    // Mesma versão: não busca de novo.
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(api.deliveries, 1);
  });

  test('certificado trocado na central: busca de novo; desligada: apaga do caixa', () async {
    final store = _Store()..values['terminal_fiscal_seed'] = seed;
    final api = _Api();
    final database = _database(enabled: true);
    final service = NfceCredentialService(api: api, database: database, store: store);
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(api.deliveries, 1);

    _setFiscal(database, {'enabled': true, 'environment': 2, 'contingency_hours': 24, 'credential_version': 'nova:versao'});
    expect(service.readiness, NfceReadiness.waiting);
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(api.deliveries, 2);

    _setFiscal(database, {'enabled': false, 'environment': 2, 'contingency_hours': 24, 'credential_version': null});
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(database.nfceCredential, isNull);
    expect(service.readiness, NfceReadiness.off);
    expect(nfceStatusText(database, DateTime.now()), isNull);
  });

  test('sem internet não marca erro; recusa da central e entrega que não abre ficam registradas', () async {
    final api = _Api()..failure = const ApiException('FA001');
    final database = _database(enabled: true);
    final service = NfceCredentialService(api: api, database: database, store: _Store()..values['terminal_fiscal_seed'] = seed);
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(service.lastError, isNull);
    expect(service.readiness, NfceReadiness.waiting);

    api.failure = const ApiException('FA943');
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(service.lastError, 'FA943');

    // Chave do caixa diferente da que a central usou: não abre e nada é guardado.
    api.failure = null;
    final otherStore = _Store();
    final other = NfceCredentialService(api: api, database: database, store: otherStore);
    await other.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    expect(other.lastError, 'FA732');
    expect(database.nfceCredential, isNull);
    expect(otherStore.values['terminal_fiscal_seed'], isNotNull);
  });

  test('certificado vencido aparece na barra', () async {
    final database = _database(enabled: true);
    final service = NfceCredentialService(api: _Api(), database: database, store: _Store()..values['terminal_fiscal_seed'] = seed);
    await service.refresh(accessToken: 't', terminalId: _terminalId, sign: _sign);
    final validTo = database.nfceCredential!.validTo;
    expect(nfceReadiness(database, validTo.add(const Duration(seconds: 1))), NfceReadiness.expired);
    expect(nfceStatusText(database, validTo.add(const Duration(seconds: 1))), 'NFC-e: certificado vencido');
  });
}
