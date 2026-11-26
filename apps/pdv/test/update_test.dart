import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:farmaerp_pdv/update/update_api.dart';
import 'package:farmaerp_pdv/update/update_service.dart';
import 'package:farmaerp_pdv/update/update_signature.dart';
import 'package:flutter_test/flutter_test.dart';

/// Central falsa: oferece uma versão, entrega o arquivo (em partes, se pedir) e guarda os relatos.
class FakeUpdateApi implements UpdateApi {
  AvailableRelease? offered;
  List<int> content = const [];
  int? cutAt;
  final reports = <Map<String, String?>>[];
  final ranges = <int>[];
  int checks = 0;

  @override
  Future<AvailableRelease?> check({required String accessToken, required String platform, required String current}) async {
    checks += 1;
    return offered;
  }

  @override
  Future<void> download({required String accessToken, required String releaseId, required File target}) async {
    final already = target.existsSync() ? target.lengthSync() : 0;
    ranges.add(already);
    final end = cutAt ?? content.length;
    cutAt = null;
    target.writeAsBytesSync(content.sublist(already, end), mode: FileMode.append);
  }

  @override
  Future<void> report({required String accessToken, required String releaseId, required String status, String? detail}) async {
    reports.add({'id': releaseId, 'status': status, 'detail': detail});
  }
}

void main() {
  late Directory root;
  late FakeUpdateApi api;
  late SimpleKeyPair keys;
  late String publicKey;
  late List<List<Object>> launched;

  Future<AvailableRelease> release(List<int> content, {String version = '1.1.0', String id = 'r-1', bool badSignature = false}) async {
    final sha = (await Sha256().hash(content)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final manifest = ReleaseManifest(app: 'pdv', platform: 'windows', version: version, sha256: sha, size: content.length);
    final signer = badSignature ? await Ed25519().newKeyPair() : keys;
    final signature = await Ed25519().sign(manifest.message(), keyPair: signer);
    return AvailableRelease(
      id: id, app: 'pdv', platform: 'windows', version: version, fileName: 'FarmaERP-PDV-Setup-$version.exe',
      size: content.length, sha256: sha, signature: base64.encode(signature.bytes),
    );
  }

  UpdateService service({String version = '1.0.0', String platform = 'windows'}) => UpdateService(
    api: api,
    accessToken: () async => 'token',
    directory: Directory('${root.path}/updates'),
    databaseFile: File('${root.path}/data/farmaerp.db'),
    currentVersion: version,
    platform: platform,
    publicKeys: [publicKey],
    installerCache: File('${root.path}/app/installer/FarmaERP-PDV-Setup.exe'),
    launch: (installer, arguments) async => launched.add([installer, arguments]),
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('farmaerp-update-');
    api = FakeUpdateApi();
    keys = await Ed25519().newKeyPair();
    publicKey = base64.encode((await keys.extractPublicKey()).bytes);
    launched = [];
    File('${root.path}/data/farmaerp.db')
      ..createSync(recursive: true)
      ..writeAsStringSync('banco da versão 1.0.0');
    File('${root.path}/app/installer/FarmaERP-PDV-Setup.exe')
      ..createSync(recursive: true)
      ..writeAsStringSync('instalador 1.0.0');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('as chaves do PDV são as de scripts/release/update-keys.json', () {
    final file = jsonDecode(File('../../scripts/release/update-keys.json').readAsStringSync()) as Map<String, dynamic>;
    expect(builtInUpdatePublicKeys, (file['keys'] as List).cast<String>());
  });

  test('a assinatura feita pelo CI (Node) confere aqui, com o mesmo texto', () async {
    // Vetor gerado com scripts/release/release-format.mjs e uma chave só de teste.
    const manifest = ReleaseManifest(app: 'pdv', platform: 'windows', version: '1.2.3', sha256: 'abababababababababababababababababababababababababababababababab', size: 1234);
    const key = '4QEz75MjJd2nYEfitDNNoY+r+dsiHWAqVx04bVxNVQE=';
    const signature = '/vh8UA46rC/GI0QWkZOZYM9iYeqoZw1eR4anrh/sWlD8TEUHdrW+0Pv2xh9YYjXPaNBvjTae9Wch9ouKwpbKCw==';
    expect(await verifyReleaseSignature(manifest, signature, [key]), isTrue);
    expect(await verifyReleaseSignature(const ReleaseManifest(app: 'pdv', platform: 'windows', version: '1.2.4', sha256: 'abababababababababababababababababababababababababababababababab', size: 1234), signature, [key]), isFalse);
    expect(await verifyReleaseSignature(manifest, signature, []), isFalse);
    expect(await verifyReleaseSignature(manifest, 'não é base64', [key]), isFalse);
  });

  test('baixa em partes, confere e fica pronta; informa a central', () async {
    final content = List<int>.generate(5000, (i) => i % 251);
    api.offered = await release(content);
    api.content = content;
    api.cutAt = 1200;
    final updates = service();
    await updates.load();
    // Primeira tentativa cai no meio: a parte fica guardada e não vira "pronta".
    await updates.tick();
    expect(updates.hasReady, isFalse);
    await updates.tick();
    expect(api.ranges, [0, 1200]);
    expect(updates.hasReady, isTrue);
    expect(updates.readyVersion, '1.1.0');
    expect(api.reports, [{'id': 'r-1', 'status': 'downloaded', 'detail': null}]);
    // Com uma versão pronta, não pergunta de novo.
    final checks = api.checks;
    await updates.tick();
    expect(api.checks, checks);
  });

  test('arquivo adulterado ou assinatura de outra chave: apaga, informa e não tenta de novo', () async {
    final content = List<int>.generate(3000, (i) => i % 7);
    api.offered = await release(content);
    api.content = [...content]..[10] = 99;
    final updates = service();
    await updates.load();
    await updates.tick();
    expect(updates.hasReady, isFalse);
    expect(api.reports.single, {'id': 'r-1', 'status': 'failed', 'detail': 'Resumo (SHA-256) diferente do publicado.'});
    api.content = content;
    await updates.tick();
    expect(updates.hasReady, isFalse);

    api.offered = await release(content, id: 'r-2', badSignature: true);
    await updates.tick();
    expect(api.reports.last, {'id': 'r-2', 'status': 'failed', 'detail': 'Assinatura não confere.'});
    expect(Directory('${root.path}/updates/downloads').listSync(), isEmpty);
  });

  test('aplica: copia o banco e o instalador atual, abre o instalador sem perguntas', () async {
    final content = utf8.encode('instalador 1.1.0');
    api.offered = await release(content);
    api.content = content;
    final updates = service();
    await updates.load();
    await updates.tick();
    await updates.apply();
    expect(launched.single[1], silentInstallArguments);
    expect(File(launched.single[0] as String).readAsStringSync(), 'instalador 1.1.0');
    expect(File('${root.path}/updates/backup/1.0.0/farmaerp.db').readAsStringSync(), 'banco da versão 1.0.0');
    expect(File('${root.path}/updates/rollback/FarmaERP-PDV-Setup-1.0.0.exe').readAsStringSync(), 'instalador 1.0.0');
    expect(updates.hasReady, isFalse);
  });

  test('versão nova abre o banco: aplicada e informada; limpa as cópias', () async {
    final content = utf8.encode('instalador 1.1.0');
    api.offered = await release(content);
    api.content = content;
    final old = service();
    await old.load();
    await old.tick();
    await old.apply();

    final fresh = service(version: '1.1.0');
    await fresh.load();
    expect(fresh.verifyingNewVersion, isTrue);
    await fresh.confirmApplied();
    expect(fresh.verifyingNewVersion, isFalse);
    api.offered = null;
    await fresh.tick();
    expect(api.reports.last, {'id': 'r-1', 'status': 'applied', 'detail': null});
    expect(Directory('${root.path}/updates/backup').existsSync(), isFalse);
  });

  test('versão nova não abre o banco: devolve a cópia, reinstala a anterior e não pega mais essa', () async {
    final content = utf8.encode('instalador 1.1.0');
    api.offered = await release(content);
    api.content = content;
    final old = service();
    await old.load();
    await old.tick();
    await old.apply();
    // A versão nova mexeu no banco antes de falhar.
    File('${root.path}/data/farmaerp.db').writeAsStringSync('banco estragado');

    final fresh = service(version: '1.1.0');
    await fresh.load();
    expect(await fresh.rollback(StateError('migração falhou')), isTrue);
    expect(File('${root.path}/data/farmaerp.db').readAsStringSync(), 'banco da versão 1.0.0');
    expect(File(launched.last[0] as String).readAsStringSync(), 'instalador 1.0.0');
    expect(launched.last[1], silentInstallArguments);

    // De volta na 1.0.0: informa e não baixa a 1.1.0 de novo.
    final back = service();
    await back.load();
    await back.tick();
    expect(api.reports.map((r) => r['status']), ['downloaded', 'rolled_back']);
    expect(back.hasReady, isFalse);
  });

  test('o instalador não concluiu: o PDV abre na versão antiga, informa e não insiste', () async {
    final content = utf8.encode('instalador 1.1.0');
    api.offered = await release(content);
    api.content = content;
    final old = service();
    await old.load();
    await old.tick();
    await old.apply();

    final again = service();
    await again.load();
    expect(again.verifyingNewVersion, isFalse);
    expect(await again.rollback(StateError('x')), isFalse);
    await again.tick();
    expect(api.reports.last['status'], 'failed');
    expect(again.hasReady, isFalse);
  });

  test('sem instalador anterior não há como voltar; fora do Windows nada acontece', () async {
    File('${root.path}/app/installer/FarmaERP-PDV-Setup.exe').deleteSync();
    final content = utf8.encode('instalador 1.1.0');
    api.offered = await release(content);
    api.content = content;
    final old = service();
    await old.load();
    await old.tick();
    await old.apply();
    final fresh = service(version: '1.1.0');
    await fresh.load();
    expect(await fresh.rollback(StateError('x')), isFalse);
    expect(File('${root.path}/data/farmaerp.db').readAsStringSync(), 'banco da versão 1.0.0');

    final linux = service(platform: 'linux');
    await linux.load();
    await linux.tick();
    expect(linux.hasReady, isFalse);
  });
}
