// Ponta a ponta com a API e o banco reais. Roda só com PDV_E2E_API apontando para uma API local
// com o seed de desenvolvimento (ex.: http://localhost:3001); sem a variável, fica de fora.
import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'app_test.dart' show MemoryStore;

final _api = Platform.environment['PDV_E2E_API'];
const _branch = '019a0000-0000-7000-8000-000000000005';
const _dipirona = '019a0000-0000-7000-8000-000000000027';

void main() {
  test(
    'terminal novo faz a carga inicial e recebe a mudança de preço',
    () async {
      final base = _api!;
      final host = Uri.parse(base).host;
      if (!['localhost', '127.0.0.1'].contains(host)) {
        fail('O teste de ponta a ponta só roda contra a API local.');
      }
      Future<Map<String, dynamic>> admin(String path, Map<String, Object?> body, {String? token}) async {
        final response = await http.post(
          Uri.parse('$base$path'),
          headers: {'Content-Type': 'application/json', 'Authorization': ?(token == null ? null : 'Bearer $token')},
          body: jsonEncode(body),
        );
        expect(response.statusCode, inInclusiveRange(200, 299), reason: '$path: ${response.body}');
        return response.body.isEmpty ? {} : jsonDecode(response.body) as Map<String, dynamic>;
      }

      // Credenciais do seed de desenvolvimento.
      final session = (await admin('/auth/login', {
        'email': 'admin@farmaerp.test',
        'password': 'farmaerp-dev-123',
      }))['token'] as String;

      final client = HttpTerminalApi(baseUrl: base);
      final identity = await TerminalIdentity.loadOrCreate(MemoryStore());
      final pairing = await client.createPairing(
        publicKey: identity.publicKey,
        signature: await identity.sign('farmaerp-terminal-pairing:${identity.publicKey}'),
        platform: 'windows',
        deviceName: 'CAIXA-E2E',
        appVersion: '0.1.0',
        keyStorage: 'system',
      );
      final terminalId = (await admin('/admin/pairing/${pairing.code}/claim', {'branchId': _branch}, token: session))['terminalId']
          as String;
      await admin(
        '/admin/terminals/$terminalId/approve',
        {'name': 'Caixa E2E ${DateTime.now().millisecondsSinceEpoch}', 'profile': 'cashier'},
        token: session,
      );
      final challenge = await client.challenge(terminalId);
      final token = await client.token(
        challenge: challenge,
        signature: await identity.sign('farmaerp-terminal-auth:$challenge'),
      );

      final database = LocalDatabase.inMemory();
      addTearDown(database.close);
      final sync = SyncService(api: client, database: database);
      try {
        await sync.pull(token.value);
        expect(sync.initialLoadDone, isTrue);
        final loaded = database.productByBarcode('7890000000017')!;
        expect(loaded.id, _dipirona);
        expect(loaded.priceCents, 1290);
        expect(database.counts()['app_user'], greaterThan(0));
        expect(database.counts()['fiscal_series'], 2);

        await admin('/admin/products/$_dipirona/prices', {'branchId': _branch, 'price': 10.75, 'reason': 'Teste E2E'}, token: session);
        await sync.pull(token.value);
        expect(database.productByBarcode('7890000000017')?.priceCents, 1075);

        // Subida: um aviso do PDV chega à central; o reenvio não duplica.
        database.enqueueLog({
          'level': 'warn',
          'time': DateTime.now().toUtc().toIso8601String(),
          'msg': 'Teste E2E da subida',
          'error_code': 'FA001',
          'version': '0.2.0',
        }, now: DateTime.now());
        final pending = database.nextOutboxBatch();
        await sync.push(token.value);
        expect(database.outboxPending, 0);
        expect(database.debugSelect('SELECT result FROM outbox').single['result'], 'applied');
        final again = await client.push(accessToken: token.value, items: pending);
        expect(again.single.status, 'duplicate');
      } finally {
        await admin('/admin/products/$_dipirona/prices', {'branchId': _branch, 'price': null}, token: session);
        await admin('/admin/terminals/$terminalId/revoke', {'reason': 'Fim do teste E2E'}, token: session);
      }
      // Revogado não baixa mais nada, mesmo com o token ainda válido.
      await expectLater(
        sync.pull(token.value),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA305')),
      );
    },
    skip: _api == null ? 'defina PDV_E2E_API para rodar contra a API local' : false,
  );
}
