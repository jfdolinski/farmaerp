// Atualização ponta a ponta com a API e o banco reais. Roda só com PDV_E2E_API (API local com o seed
// de desenvolvimento) e PDV_E2E_RELEASE_TOKEN (o RELEASE_UPLOAD_TOKEN dela). A API precisa de
// RELEASES_DIR e de UPDATE_TEST_PUBLIC_KEY com a chave de teste abaixo.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_identity.dart';
import 'package:farmaerp_pdv/update/update_api.dart';
import 'package:farmaerp_pdv/update/update_service.dart';
import 'package:farmaerp_pdv/update/update_signature.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'app_test.dart' show MemoryStore;

final _api = Platform.environment['PDV_E2E_API'];
final _releaseToken = Platform.environment['PDV_E2E_RELEASE_TOKEN'];
const _branch = '019a0000-0000-7000-8000-000000000005';

/// Semente da chave só de teste (a mesma do vetor de update_test.dart). Nunca vale em produção.
const testKeySeed = 'BB0cTaptx24adkFgjfJVXEus8u9imjXIBFndBTPZffs=';
const testPublicKey = '4QEz75MjJd2nYEfitDNNoY+r+dsiHWAqVx04bVxNVQE=';

void main() {
  test(
    'versão publicada chega ao terminal de teste: baixa, confere e informa a central',
    () async {
      final base = _api!;
      if (!['localhost', '127.0.0.1'].contains(Uri.parse(base).host)) fail('Só contra a API local.');
      Future<Object?> call(String method, String path, {Map<String, Object?>? body, String? token}) async {
        final request = http.Request(method, Uri.parse('$base$path'))
          ..headers.addAll({'Content-Type': 'application/json', 'Authorization': ?(token == null ? null : 'Bearer $token')});
        if (body != null) request.body = jsonEncode(body);
        final response = await http.Response.fromStream(await request.send());
        expect(response.statusCode, inInclusiveRange(200, 299), reason: '$path: ${response.body}');
        return response.body.isEmpty ? null : jsonDecode(response.body);
      }

      final session = ((await call('POST', '/auth/login', body: {'email': 'admin@farmaerp.test', 'password': 'farmaerp-dev-123'}))
          as Map)['token'] as String;
      final client = HttpTerminalApi(baseUrl: base);
      final identity = await TerminalIdentity.loadOrCreate(MemoryStore());
      final pairing = await client.createPairing(
        publicKey: identity.publicKey,
        signature: await identity.sign('farmaerp-terminal-pairing:${identity.publicKey}'),
        platform: 'windows',
        deviceName: 'CAIXA-ATUALIZACAO',
        appVersion: '0.1.0',
        keyStorage: 'system',
      );
      final terminalId = ((await call('POST', '/admin/pairing/${pairing.code}/claim', body: {'branchId': _branch}, token: session))
          as Map)['terminalId'] as String;
      await call('POST', '/admin/terminals/$terminalId/approve',
          body: {'name': 'Caixa atualização ${DateTime.now().millisecondsSinceEpoch}', 'profile': 'cashier'}, token: session);
      await call('POST', '/admin/terminals/$terminalId/update-ring', body: {'ring': 'test'}, token: session);
      final challenge = await client.challenge(terminalId);
      final token = await client.token(challenge: challenge, signature: await identity.sign('farmaerp-terminal-auth:$challenge'));

      // Publica uma versão como o CI: assinada com a chave de teste.
      final version = '${8000 + DateTime.now().millisecondsSinceEpoch % 1000}.${DateTime.now().second}.${DateTime.now().millisecond}';
      final content = List<int>.generate(200000, (i) => (i * 31) % 256);
      final sha = (await Sha256().hash(content)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final manifest = ReleaseManifest(app: 'pdv', platform: 'windows', version: version, sha256: sha, size: content.length);
      final keyPair = await Ed25519().newKeyPairFromSeed(base64.decode(testKeySeed));
      expect(base64.encode((await keyPair.extractPublicKey()).bytes), testPublicKey);
      final signature = base64.encode((await Ed25519().sign(manifest.message(), keyPair: keyPair)).bytes);
      final upload = await http.post(
        Uri.parse('$base/releases').replace(queryParameters: {
          'app': 'pdv', 'platform': 'windows', 'version': version, 'sha256': sha, 'size': '${content.length}',
          'signature': signature, 'fileName': 'FarmaERP-PDV-Setup-$version.exe',
        }),
        headers: {'Authorization': 'Bearer $_releaseToken', 'Content-Type': 'application/octet-stream'},
        body: content,
      );
      expect(upload.statusCode, 201, reason: upload.body);
      final releaseId = (jsonDecode(upload.body) as Map)['id'] as String;

      final root = Directory.systemTemp.createTempSync('farmaerp-update-e2e-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/farmaerp.db').writeAsStringSync('banco');
      final updates = UpdateService(
        api: HttpUpdateApi(baseUrl: base),
        accessToken: () async => token.value,
        directory: Directory('${root.path}/updates'),
        databaseFile: File('${root.path}/farmaerp.db'),
        currentVersion: '0.1.0',
        platform: 'windows',
        publicKeys: [testPublicKey],
        installerCache: File('${root.path}/nao-existe.exe'),
        launch: (_, _) async {},
      );
      await updates.load();
      await updates.tick();
      expect(updates.readyVersion, version);
      final installer = Directory('${root.path}/updates/downloads').listSync().whereType<File>().single;
      expect(installer.readAsBytesSync(), content);

      final terminals = (await call('GET', '/admin/terminals', token: session)) as List;
      final row = terminals.cast<Map<String, dynamic>>().firstWhere((t) => t['id'] == terminalId);
      expect(row['last_update_status'], 'downloaded');
      expect(row['last_update_version'], version);

      // Limpeza: a versão de teste sai de circulação.
      await call('POST', '/platform/releases/$releaseId/status', body: {'status': 'withdrawn'}, token: session);
    },
    skip: _api == null || _releaseToken == null ? 'defina PDV_E2E_API e PDV_E2E_RELEASE_TOKEN para rodar contra a API local' : false,
  );
}
