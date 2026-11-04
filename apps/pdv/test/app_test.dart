import 'dart:io';

import 'package:farmaerp_pdv/core/secret_store.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_controller.dart';
import 'package:farmaerp_pdv/terminal/terminal_identity.dart';
import 'package:farmaerp_pdv/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryStore implements SecretStore {
  final values = <String, String>{};

  @override
  String kind = 'system';

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// API simulada: cada teste define a situação do terminal.
class FakeApi implements TerminalApi {
  String pairingState = 'waiting';
  String terminalState = 'pending';
  String code = 'K7M2XQ9P';
  Object? failure;
  Object? heartbeatFailure;
  int heartbeats = 0;
  int? terminalNumber = 2;
  int logins = 0;
  int creations = 0;
  String? lastKeyStorage;
  String? lastPublicKey;
  DateTime tokenExpiresAt = DateTime(2030);

  void _maybeFail() {
    if (failure != null) throw failure!;
  }

  @override
  Future<PairingRequest> createPairing({
    required String publicKey,
    required String signature,
    required String platform,
    required String deviceName,
    required String appVersion,
    required String keyStorage,
  }) async {
    _maybeFail();
    creations += 1;
    lastKeyStorage = keyStorage;
    lastPublicKey = publicKey;
    return PairingRequest(requestId: 'req-$creations', code: code);
  }

  @override
  Future<PairingStatus> pairingStatus({
    required String requestId,
    required String publicKey,
  }) async {
    _maybeFail();
    return PairingStatus(
      status: pairingState,
      terminalId: pairingState == 'claimed' ? 'term-1' : null,
      terminalStatus: pairingState == 'claimed' ? terminalState : null,
    );
  }

  @override
  Future<String> challenge(String terminalId) async {
    _maybeFail();
    return 'desafio';
  }

  @override
  Future<AccessToken> token({
    required String challenge,
    required String signature,
  }) async {
    _maybeFail();
    logins += 1;
    return AccessToken(value: 'token-$logins', expiresAt: tokenExpiresAt);
  }

  @override
  Future<int?> heartbeat({
    required String accessToken,
    required String appVersion,
  }) async {
    _maybeFail();
    if (heartbeatFailure != null) throw heartbeatFailure!;
    heartbeats += 1;
    return terminalNumber;
  }
}

void main() {
  late FakeApi api;
  late MemoryStore store;

  TerminalController newController() => TerminalController(
    api: api,
    store: store,
    platform: 'windows',
    deviceName: 'CAIXA-01',
    appVersion: '0.1.0',
    // Intervalo longo: os testes avançam com tick().
    pollInterval: const Duration(hours: 1),
    heartbeatInterval: const Duration(hours: 1),
    clock: () => DateTime(2026, 11, 4, 12),
  );

  setUp(() {
    api = FakeApi();
    store = MemoryStore();
  });

  Future<TerminalController> ready() async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.start();
    api
      ..pairingState = 'claimed'
      ..terminalState = 'active';
    await controller.tick();
    expect(controller.phase, TerminalPhase.ready);
    return controller;
  }

  group('identidade', () {
    test('a assinatura em Dart é igual à gerada em Node', () async {
      // Mesma semente e mensagem de apps/api/src/terminals/terminal-crypto.spec.ts.
      final identity = await TerminalIdentity.fromSeed(List.filled(32, 7));
      expect(
        identity.publicKey,
        '6kpsY-KcUgq-9VB7Ey7F-ZVHdq6-vnuSQh7qaRRG0iw',
      );
      expect(
        await identity.sign('farmaerp-teste'),
        'ns1zZWcdS4PAAice6923Vixl18j7ZsHMVMMM_ke9q0jpurM8deQSs1XJd-AGLi7752Jks95zW04JeScuqMFJCg',
      );
    });

    test('mantém a mesma chave entre aberturas', () async {
      final first = await TerminalIdentity.loadOrCreate(store);
      final second = await TerminalIdentity.loadOrCreate(store);
      expect(second.publicKey, first.publicKey);
      expect(first.publicKey, hasLength(43));
    });

    test('gera outra chave depois de apagar', () async {
      final first = await TerminalIdentity.loadOrCreate(store);
      await TerminalIdentity.erase(store);
      final second = await TerminalIdentity.loadOrCreate(store);
      expect(second.publicKey, isNot(first.publicKey));
    });
  });

  group('pareamento', () {
    test('mostra o código formatado e informa a guarda da chave', () async {
      store.kind = 'file';
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.phase, TerminalPhase.showingCode);
      expect(controller.displayCode, 'K7M2-XQ9P');
      expect(api.lastKeyStorage, 'file');
    });

    test('passa por aguardando aprovação até ficar pronto', () async {
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      api.pairingState = 'claimed';
      await controller.tick();
      expect(controller.phase, TerminalPhase.awaitingApproval);
      expect(controller.displayCode, isNull);

      api.terminalState = 'active';
      await controller.tick();
      expect(controller.phase, TerminalPhase.ready);
      expect(api.heartbeats, 1);
    });

    test('código expirado gera outro automaticamente', () async {
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      api
        ..pairingState = 'expired'
        ..code = 'ABCD2345';
      await controller.tick();

      expect(controller.phase, TerminalPhase.showingCode);
      expect(controller.displayCode, 'ABCD-2345');
      expect(api.creations, 2);
    });

    test('solicitação desconhecida gera outro código', () async {
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      api.failure = const ApiException('FA301');
      await controller.tick();
      expect(controller.phase, TerminalPhase.showingCode);
    });

    test('recusado na aprovação vai para revogado', () async {
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      api
        ..pairingState = 'claimed'
        ..terminalState = 'revoked';
      await controller.tick();
      expect(controller.phase, TerminalPhase.revoked);
    });

    test('sem conexão ao abrir, avisa e tenta de novo', () async {
      api.failure = const ApiException('FA001', traceId: '019a-abcdef12');
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.online, isFalse);
      expect(controller.notice?.message, 'Sistema indisponível no momento.');

      api.failure = null;
      await controller.tick();
      expect(controller.phase, TerminalPhase.showingCode);
      expect(controller.online, isTrue);
      expect(controller.notice, isNull);
    });

    test('sem conexão enquanto aguarda, mantém o código na tela', () async {
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.start();

      api.failure = const ApiException('FA001');
      await controller.tick();
      expect(controller.phase, TerminalPhase.showingCode);
      expect(controller.displayCode, 'K7M2-XQ9P');
      expect(controller.online, isFalse);
    });

    test('ao reabrir aguardando, busca o código de novo', () async {
      final first = newController();
      await first.start();
      first.dispose();

      final second = newController();
      addTearDown(second.dispose);
      await second.start();
      expect(second.phase, TerminalPhase.showingCode);
      expect(second.displayCode, 'K7M2-XQ9P');
    });

    test('ao reabrir, descobre que foi aprovado enquanto estava fechado', () async {
      final first = newController();
      await first.start();
      first.dispose();

      api
        ..pairingState = 'claimed'
        ..terminalState = 'active';
      final second = newController();
      addTearDown(second.dispose);
      await second.start();
      expect(second.phase, TerminalPhase.ready);
    });
  });

  group('sinal de vida', () {
    test('reaproveita o token enquanto ele vale', () async {
      final controller = await ready();
      await controller.tick();
      await controller.tick();
      expect(api.heartbeats, 3);
      expect(api.logins, 1);
    });

    test('renova o token perto do vencimento', () async {
      api.tokenExpiresAt = DateTime(2026, 11, 4, 12, 0, 30);
      final controller = await ready();
      api.tokenExpiresAt = DateTime(2030);
      await controller.tick();
      expect(api.logins, 2);
    });

    test('recebe e guarda o número do terminal', () async {
      final controller = await ready();
      expect(controller.terminalNumber, 2);

      api.failure = const ApiException('FA001');
      final reopened = newController();
      addTearDown(reopened.dispose);
      await reopened.start();
      expect(reopened.terminalNumber, 2);
    });

    test('novo cadastro esquece o número antigo', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA305');
      await controller.tick();

      api
        ..heartbeatFailure = null
        ..pairingState = 'waiting';
      await controller.startNewPairing();
      expect(controller.terminalNumber, isNull);
    });

    test('bloqueio muda a tela na hora', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA304');
      await controller.tick();
      expect(controller.phase, TerminalPhase.blocked);
    });

    test('continua tentando e volta ao ser desbloqueado', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA304');
      await controller.tick();

      api.heartbeatFailure = null;
      await controller.tick();
      expect(controller.phase, TerminalPhase.ready);
      expect(controller.notice, isNull);
    });

    test('revogação é definitiva', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA305');
      await controller.tick();
      expect(controller.phase, TerminalPhase.revoked);
    });

    test('sem conexão continua pronto, sem parar o caixa', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA001');
      await controller.tick();
      expect(controller.phase, TerminalPhase.ready);
      expect(controller.online, isFalse);
    });

    test('token recusado autentica de novo antes de desistir', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA306');
      await controller.tick();
      expect(controller.phase, TerminalPhase.ready);

      api.heartbeatFailure = null;
      await controller.tick();
      expect(api.logins, 2);
      expect(controller.phase, TerminalPhase.ready);
    });

    test('terminal não reconhecido com assinatura nova vai para revogado', () async {
      final controller = await ready();
      api.heartbeatFailure = const ApiException('FA306');
      await controller.tick();

      api.failure = const ApiException('FA306');
      await controller.tick();
      expect(controller.phase, TerminalPhase.revoked);
    });

    test('bloqueado continua bloqueado ao reabrir offline', () async {
      final first = await ready();
      api.heartbeatFailure = const ApiException('FA304');
      await first.tick();

      api
        ..heartbeatFailure = null
        ..failure = const ApiException('FA001');
      final second = newController();
      addTearDown(second.dispose);
      await second.start();
      expect(second.phase, TerminalPhase.blocked);
    });

    test('revogado continua revogado ao reabrir', () async {
      final first = await ready();
      api.heartbeatFailure = const ApiException('FA305');
      await first.tick();

      final second = newController();
      addTearDown(second.dispose);
      await second.start();
      expect(second.phase, TerminalPhase.revoked);
    });

    test('novo cadastro usa outra chave', () async {
      final controller = await ready();
      final oldKey = api.lastPublicKey;
      api.heartbeatFailure = const ApiException('FA305');
      await controller.tick();

      api
        ..heartbeatFailure = null
        ..pairingState = 'waiting';
      await controller.startNewPairing();

      expect(controller.phase, TerminalPhase.showingCode);
      expect(api.lastPublicKey, isNot(oldKey));
    });
  });

  group('cliente HTTP', () {
    HttpTerminalApi apiWith(Future<http.Response> Function(http.Request) fn) =>
        HttpTerminalApi(baseUrl: 'http://api', client: MockClient(fn));

    test('envia o ID de rastreio em UUID v7', () async {
      String? trace;
      await apiWith((request) async {
        trace = request.headers['X-Trace-Id'];
        return http.Response('{"challenge":"abc"}', 200);
      }).challenge('term-1');
      expect(trace, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7')));
    });

    test('usa o código e o rastreio devolvidos pela API', () async {
      final call = apiWith(
        (request) async => http.Response(
          '{"code":"FA304","message":"m","traceId":"x"}',
          403,
        ),
      ).challenge('term-1');
      await expectLater(
        call,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA304')),
      );
    });

    test('resposta que não é JSON vira o erro genérico', () async {
      final call = apiWith(
        (request) async => http.Response('<html>', 502),
      ).challenge('term-1');
      await expectLater(
        call,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA000')),
      );
    });

    test('falha de rede vira FA001', () async {
      final call = apiWith((request) async {
        throw const SocketException('sem rede');
      }).challenge('term-1');
      await expectLater(
        call,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FA001')),
      );
    });

    test('envia o token só no sinal de vida', () async {
      String? authorization;
      await apiWith((request) async {
        authorization = request.headers['Authorization'];
        return http.Response('{"status":"active"}', 200);
      }).heartbeat(accessToken: 'abc', appVersion: '0.1.0');
      expect(authorization, 'Bearer abc');
    });
  });

  group('guarda da chave', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('farmaerp_key_'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('arquivo grava, lê e apaga', () async {
      final file = FileSecretStore(File('${directory.path}/terminal.secret'));
      await file.write('a', '1');
      await file.write('b', '2');
      expect(await file.read('a'), '1');
      await file.delete('a');
      expect(await file.read('a'), isNull);
      expect(await file.read('b'), '2');
    });

    test('fora do Linux, usa sempre a guarda do sistema', () async {
      final system = MemoryStore();
      final chosen = await createSecretStore(
        dataDirectory: directory,
        systemStore: system,
        isLinux: false,
      );
      expect(chosen, same(system));
    });

    test('no Linux com chaveiro, usa a guarda do sistema', () async {
      final system = MemoryStore();
      final chosen = await createSecretStore(
        dataDirectory: directory,
        systemStore: system,
        isLinux: true,
      );
      expect(chosen, same(system));
      expect(system.values, isEmpty);
    });

    test('no Linux sem chaveiro, recorre ao arquivo', () async {
      final chosen = await createSecretStore(
        dataDirectory: directory,
        systemStore: _BrokenStore(),
        isLinux: true,
      );
      expect(chosen.kind, 'file');
    });
  });

  group('telas', () {
    Future<void> pump(WidgetTester tester, TerminalController controller) =>
        tester.pumpWidget(
          MaterialApp(home: TerminalScreen(controller: controller)),
        );

    testWidgets('mostra o código e as instruções', (tester) async {
      await tester.runAsync(() async {
        final controller = newController();
        addTearDown(controller.dispose);
        await controller.start();
        await pump(tester, controller);
      });
      await tester.pump();

      expect(find.text('K7M2-XQ9P'), findsOneWidget);
      expect(find.text('Cadastre este terminal'), findsOneWidget);
    });

    testWidgets('mostra o número do terminal aprovado', (tester) async {
      await tester.runAsync(() async {
        final controller = await ready();
        await pump(tester, controller);
      });
      await tester.pump();

      expect(find.text('Terminal número 2'), findsOneWidget);
    });

    testWidgets('mostra o bloqueio com a referência', (tester) async {
      await tester.runAsync(() async {
        final controller = await ready();
        api.heartbeatFailure = const ApiException(
          'FA304',
          traceId: '019a0000-0000-7000-8000-0000a1b2c3d4',
        );
        await controller.tick();
        await pump(tester, controller);
      });
      await tester.pump();

      expect(find.text('Terminal bloqueado'), findsOneWidget);
      expect(find.text('Código FA304 · Ref. a1b2c3d4'), findsOneWidget);
    });

    testWidgets('revogado oferece novo cadastro', (tester) async {
      await tester.runAsync(() async {
        final controller = await ready();
        api.heartbeatFailure = const ApiException('FA305');
        await controller.tick();
        await pump(tester, controller);
      });
      await tester.pump();

      expect(find.text('Fazer novo cadastro'), findsOneWidget);
    });

    testWidgets('avisa quando está sem conexão', (tester) async {
      await tester.runAsync(() async {
        final controller = await ready();
        api.heartbeatFailure = const ApiException('FA001');
        await controller.tick();
        await pump(tester, controller);
      });
      await tester.pump();

      expect(find.byKey(const Key('offline-notice')), findsOneWidget);
      expect(find.text('Terminal aprovado'), findsOneWidget);
    });
  });
}

class _BrokenStore implements SecretStore {
  @override
  String get kind => 'system';

  @override
  Future<String?> read(String key) => throw StateError('sem chaveiro');

  @override
  Future<void> write(String key, String value) =>
      throw StateError('sem chaveiro');

  @override
  Future<void> delete(String key) => throw StateError('sem chaveiro');
}
