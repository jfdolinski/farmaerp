import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:farmaerp_pdv/face/face_camera.dart';
import 'package:farmaerp_pdv/face/face_engine.dart';
import 'package:farmaerp_pdv/face/face_math.dart';
import 'package:farmaerp_pdv/face/face_reader.dart';
import 'package:farmaerp_pdv/face/face_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'auth_test.dart' as auth_fixture;
import 'auth_test.dart' show seeded, faceId, anyId, managerId;
import 'pos_test.dart' show FakePrinter, hashFor;

/// Rosto falso em posição de frente (os pontos do modelo de referência, ampliados).
FaceBox frontal({double yaw = 0, double size = 200}) {
  final s = size / 112;
  final nose = sfaceTemplate[2];
  return FaceBox(
    x: 100,
    y: 50,
    width: size,
    height: size,
    score: 0.99,
    landmarks: [
      for (var i = 0; i < 5; i += 1)
        FacePoint(100 + (sfaceTemplate[i].x + (i == 2 ? yaw * 35.2 : 0)) * s, 50 + (i == 2 ? nose.y : sfaceTemplate[i].y) * s),
    ],
  );
}

Float32List vector(int seed) {
  final random = math.Random(seed);
  return normalized([for (var i = 0; i < 128; i += 1) random.nextDouble() - 0.5]);
}

/// Motor falso: cada quadro devolve a próxima observação do roteiro.
class FakeEngine implements FaceEngine {
  FakeEngine(this.script);

  final List<({List<FaceBox> faces, double liveness, Float32List embedding})> script;
  int _frame = -1;

  @override
  String get model => 'sface-2021dec-int8';

  ({List<FaceBox> faces, double liveness, Float32List embedding}) get _now => script[math.min(_frame, script.length - 1)];

  @override
  Future<List<FaceBox>> detect(Frame frame) async {
    _frame += 1;
    return _now.faces;
  }

  @override
  Future<double> liveness(Frame frame, FaceBox face) async => _now.liveness;

  @override
  Future<Float32List> embed(Frame frame, FaceBox face) async => _now.embedding;

  @override
  Future<void> close() async {}
}

class FakeCamera implements FaceCamera {
  FakeCamera({this.opens = true, this.failAfter, this.missFirst = 0, this.missAt = const {}});

  final bool opens;
  final int? failAfter;

  /// Recém-ligada: os primeiros quadros ainda não existem.
  final int missFirst;

  /// Tentativas (contando de 1) que voltam sem quadro.
  final Set<int> missAt;
  int captures = 0;
  bool closed = false;

  @override
  Future<bool> open() async => opens;

  @override
  Future<Frame?> capture() async {
    captures += 1;
    if (failAfter != null && captures > failAfter!) return null;
    if (captures <= missFirst || missAt.contains(captures)) return null;
    return Frame(width: 640, height: 480, rgb: Uint8List(640 * 480 * 3));
  }

  @override
  Widget preview() => const SizedBox(key: Key('fake-preview'));

  @override
  Future<void> close() async => closed = true;
}

/// Espera (tempo real e do teste) até a condição valer: leitura da câmera e PIN levam um tempo.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i += 1) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Roteiro de uma leitura boa: de frente, vira, volta de frente.
List<({List<FaceBox> faces, double liveness, Float32List embedding})> goodRead(Float32List who, {int front = 3}) => [
  for (var i = 0; i < front; i += 1) (faces: [frontal()], liveness: 2.0, embedding: who),
  (faces: [frontal(yaw: 0.45)], liveness: -1.0, embedding: who),
  (faces: [frontal()], liveness: 2.0, embedding: who),
];

void main() {
  group('matemática do rosto', () {
    test('decodifica o YuNet: caixa, pontos, limiar e sobrepostos', () {
      Map<String, Float32List> empty() => {
        for (final s in const [8, 16, 32]) ...{
          'cls_$s': Float32List((640 ~/ s) * (640 ~/ s)),
          'obj_$s': Float32List((640 ~/ s) * (640 ~/ s)),
          'bbox_$s': Float32List((640 ~/ s) * (640 ~/ s) * 4),
          'kps_$s': Float32List((640 ~/ s) * (640 ~/ s) * 10),
        },
      };
      final out = empty();
      void anchor(int index, double score, double dx) {
        out['cls_8']![index] = score;
        out['obj_8']![index] = score;
        out['bbox_8']!.setAll(index * 4, [0.5 + dx, 0.5, math.log(4), math.log(5)]);
        out['kps_8']!.setAll(index * 10, [for (var n = 0; n < 5; n += 1) ...[n.toDouble(), 1.0]]);
      }

      anchor(10 * 80 + 20, 1.0, 0); // linha 10, coluna 20
      anchor(10 * 80 + 21, 0.95, -0.9); // quase o mesmo lugar: sai na supressão
      anchor(40 * 80 + 60, 0.5, 0); // abaixo do limiar
      final faces = decodeYunet(out);
      expect(faces, hasLength(1));
      final face = faces.single;
      expect([face.x, face.y, face.width, face.height].map((v) => v.toStringAsFixed(1)), ['148.0', '64.0', '32.0', '40.0']);
      expect(face.landmarks.map((p) => [p.x, p.y]), [
        for (var n = 0; n < 5; n += 1) [(n + 20) * 8.0, 11 * 8.0],
      ]);
      expect(iou(face, face), closeTo(1.0, 1e-9));
    });

    test('semelhança leva os pontos ao modelo; o rosto alinhado sai do lugar certo', () {
      // Pontos do modelo girados 20 graus, ampliados 2 vezes e deslocados.
      const angle = 20 * math.pi / 180;
      final src = [
        for (final p in sfaceTemplate)
          FacePoint(2 * (p.x * math.cos(angle) - p.y * math.sin(angle)) + 30, 2 * (p.x * math.sin(angle) + p.y * math.cos(angle)) + 40),
      ];
      final m = similarityTransform(src, sfaceTemplate);
      for (var i = 0; i < 5; i += 1) {
        expect(m[0] * src[i].x + m[1] * src[i].y + m[2], closeTo(sfaceTemplate[i].x, 1e-6));
        expect(m[3] * src[i].x + m[4] * src[i].y + m[5], closeTo(sfaceTemplate[i].y, 1e-6));
      }
      // Quadro 112x112 com o rosto já no lugar: o alinhamento devolve o próprio quadro (R, G, B).
      final rgb = Uint8List(112 * 112 * 3);
      for (var i = 0; i < 112 * 112; i += 1) {
        rgb[i * 3] = i % 112;
        rgb[i * 3 + 1] = 7;
        rgb[i * 3 + 2] = 200;
      }
      final frame = Frame(width: 112, height: 112, rgb: rgb);
      final aligned = sfaceInput(frame, FaceBox(x: 0, y: 0, width: 112, height: 112, score: 1, landmarks: sfaceTemplate));
      expect(aligned[5 * 112 + 33], closeTo(33, 1e-3));
      expect(aligned[112 * 112 + 500], closeTo(7, 1e-3));
      expect(aligned[2 * 112 * 112 + 500], closeTo(200, 1e-3));
    });

    test('entradas do detector e da prova de vida; espelhamento da borda', () {
      final rgb = Uint8List(320 * 240 * 3);
      rgb.setAll(0, [10, 20, 30]);
      final detector = yunetInput(Frame(width: 320, height: 240, rgb: rgb));
      expect(detector.scale, 2.0);
      // BGR: azul primeiro.
      expect([detector.input[0], detector.input[640 * 640], detector.input[2 * 640 * 640]], [30, 20, 10]);
      expect(detector.input[639], 0); // só cabe até 640 x 480; depois, zero
      expect(detector.input[500 * 640], 0);
      expect([reflect101(-1, 5), reflect101(5, 5), reflect101(6, 5), reflect101(2, 5), reflect101(-3, 1)], [1, 3, 2, 2, 0]);
      final gray = Frame(width: 64, height: 64, rgb: Uint8List(64 * 64 * 3)..fillRange(0, 64 * 64 * 3, 102));
      final live = livenessInput(gray, const FaceBox(x: 40, y: 40, width: 40, height: 40, score: 1, landmarks: []));
      expect(live, hasLength(3 * 128 * 128));
      expect(live.every((v) => (v - 0.4).abs() < 1e-6), isTrue);
    });

    test('virada do rosto, código guardado e comparação', () {
      expect(yawOf(frontal()).abs(), lessThan(0.01));
      expect(yawOf(frontal(yaw: 0.4)), greaterThan(0.3));
      final v = vector(1);
      expect(templateFromBytes(templateBytes(v)), v);
      expect(templateBytes(v), hasLength(512));
      final average = averageTemplate([v, vector(1)]);
      expect(cosine(average, v), closeTo(1, 1e-6));
      expect(cosine(vector(1), vector(2)), lessThan(0.5));
    });
  });

  group('leitura do rosto', () {
    FaceObservation seen(FaceBox? face, {int faces = 1, double liveness = 2, Float32List? embedding}) =>
        FaceObservation(faces: faces, frameWidth: 640, face: face, liveness: liveness, embedding: embedding ?? vector(1));

    test('de frente com prova de vida, vira, volta: o código é a média', () {
      final reader = FaceReader();
      reader.observe(seen(null, faces: 0));
      expect(reader.message, 'Olhe para a câmera.');
      reader.observe(seen(frontal(), faces: 2));
      expect(reader.message, contains('Só uma pessoa'));
      reader.observe(seen(frontal(size: 60)));
      expect(reader.message, contains('mais perto'));
      reader.observe(seen(frontal(yaw: 0.4)));
      expect(reader.message, contains('de frente'));
      for (var i = 0; i < 3; i += 1) {
        reader.observe(seen(frontal()));
      }
      expect(reader.stage, FaceStage.turn);
      expect(reader.wantsEmbedding, isFalse);
      reader.observe(seen(frontal(yaw: 0.1)));
      expect(reader.stage, FaceStage.turn);
      reader.observe(seen(frontal(yaw: -0.5)));
      expect(reader.stage, FaceStage.back);
      reader.observe(seen(frontal()));
      expect(reader.stage, FaceStage.done);
      expect(cosine(reader.result!, vector(1)), closeTo(1, 1e-6));
    });

    test('foto ou tela (prova de vida falha), troca de rosto, câmera parada e tempo esgotado', () {
      final spoof = FaceReader();
      for (var i = 0; i < 3; i += 1) {
        spoof.observe(seen(frontal(), liveness: -0.5));
      }
      expect([spoof.stage, spoof.message.contains('pessoa presente')], [FaceStage.failed, true]);

      final swapped = FaceReader();
      for (var i = 0; i < 3; i += 1) {
        swapped.observe(seen(frontal()));
      }
      swapped.observe(seen(frontal(yaw: 0.5)));
      swapped.observe(seen(frontal(), embedding: vector(2)));
      expect([swapped.stage, swapped.message.contains('mudou')], [FaceStage.failed, true]);

      // Outra pessoa entra no lugar antes do desafio: recomeça a contagem.
      final restart = FaceReader();
      restart.observe(seen(frontal()));
      restart.observe(seen(frontal()));
      restart.observe(seen(frontal(), embedding: vector(3)));
      expect(restart.stage, FaceStage.front);

      final camera = FaceReader()..cameraFailed();
      expect([camera.stage, camera.cameraProblem], [FaceStage.failed, true]);

      var now = DateTime(2026, 11, 24, 10);
      final slow = FaceReader(clock: () => now);
      now = now.add(const Duration(seconds: 21));
      slow.observe(seen(frontal()));
      expect([slow.stage, slow.message.contains('Tempo esgotado')], [FaceStage.failed, true]);
    });

    test('comparação: o mais parecido, acima do limite e com folga sobre o segundo', () {
      final candidates = [(candidate: 'Ana', template: vector(1) as List<double>), (candidate: 'Bia', template: vector(2) as List<double>)];
      expect(bestFaceMatch(vector(1), candidates)?.match, 'Ana');
      expect(bestFaceMatch(vector(9), candidates), isNull);
      expect(bestFaceMatch(vector(1), <({String candidate, List<double> template})>[]), isNull);
      final twins = [(candidate: 'Ana', template: vector(1) as List<double>), (candidate: 'Gêmea', template: vector(1) as List<double>)];
      expect(bestFaceMatch(vector(1), twins), isNull);
    });

    test('lê pela câmera com o motor; câmera que para avisa', () async {
      final engine = FakeEngine(goodRead(vector(1)));
      final reader = FaceReader();
      var updates = 0;
      final result = await readFace(camera: FakeCamera(), engine: engine, reader: reader, onUpdate: () => updates += 1, cancelled: () => false, pause: Duration.zero);
      expect(cosine(result!, vector(1)), closeTo(1, 1e-6));
      expect(updates, greaterThan(4));
      final broken = FaceReader();
      final dead = FakeCamera(failAfter: 1);
      expect(await readFace(camera: dead, engine: FakeEngine(goodRead(vector(1))), reader: broken, onUpdate: () {}, cancelled: () => false, pause: Duration.zero, missPause: Duration.zero), isNull);
      expect(broken.cameraProblem, isTrue);
      // Desiste só depois de 30 tentativas seguidas sem quadro.
      expect(dead.captures, 31);
    });

    test('câmera recém-ligada, ainda sem quadro, não é câmera quebrada', () async {
      final reader = FaceReader();
      final warming = FakeCamera(missFirst: 10);
      final result = await readFace(
        camera: warming, engine: FakeEngine(goodRead(vector(1))), reader: reader, onUpdate: () {}, cancelled: () => false,
        pause: Duration.zero, missPause: Duration.zero,
      );
      expect(reader.cameraProblem, isFalse);
      expect(cosine(result!, vector(1)), closeTo(1, 1e-6));
    });

    test('a câmera fica ligada entre as leituras; desliga se falhar ou se pedirem para não manter', () async {
      var opened = 0;
      final kept = FaceService(camera: () { opened += 1; return FakeCamera(); }, engine: () async => FakeEngine(goodRead(vector(1))));
      expect(await kept.start(), isTrue);
      final first = kept.camera as FakeCamera;
      await kept.closeCamera();
      expect(first.closed, isFalse);
      expect(await kept.start(), isTrue);
      expect(kept.camera, same(first));
      expect(opened, 1);
      // Câmera que falhou desliga de verdade; a próxima leitura liga de novo.
      await kept.cameraLost();
      expect(first.closed, isTrue);
      expect(kept.camera, isNull);
      expect(await kept.start(), isTrue);
      expect(opened, 2);

      final light = FaceService(camera: FakeCamera.new, engine: () async => FakeEngine(goodRead(vector(1))), keepCameraOn: false);
      await light.start();
      final cam = light.camera as FakeCamera;
      await light.closeCamera();
      expect(cam.closed, isTrue);
      expect(light.camera, isNull);
    });

    test('um quadro perdido no meio da leitura não derruba a leitura', () async {
      final reader = FaceReader();
      final result = await readFace(
        camera: FakeCamera(missAt: {2, 3, 5, 6}), engine: FakeEngine(goodRead(vector(1))), reader: reader, onUpdate: () {},
        cancelled: () => false, pause: Duration.zero, missPause: Duration.zero, maxMissedFrames: 3,
      );
      expect(reader.cameraProblem, isFalse);
      expect(result, isNotNull);
    });
  });

  group('rosto no PDV', () {
    late LocalDatabase database;
    late PosController controller;
    final now = DateTime(2026, 11, 24, 10, 5);

    setUpAll(() async {
      auth_fixture.pin = await hashFor('2468');
    });

    setUp(() {
      database = seeded();
      controller = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: FakePrinter.new,
        terminalNumber: () => 1,
        clock: () => now,
      );
    });
    tearDown(() => database.close());

    List<Map<String, Object?>> outbox(String kind) =>
        database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

    test('cadastro: quem autoriza precisa da permissão; vale aqui na hora e sobe com o consentimento', () async {
      expect(await controller.faceEnroller('3', '2468'), isNull);
      expect(controller.notice?.reference, contains('FA822'));
      final enroller = (await controller.faceEnroller('2', '2468'))!;
      final person = database.userByCode(4)!;
      expect(person.hasFace, isFalse);
      controller.enrollFace(
        person: person, enroller: enroller, template: vector(1), model: 'sface-2021dec-int8',
        termVersion: faceTermVersion, consentedAt: now,
      );
      expect(database.userByCode(4)!.hasFace, isTrue);
      final payload = outbox('face_enrollment').single;
      expect(payload, containsPair('user_id', faceId));
      expect(payload, containsPair('enrolled_by', managerId));
      expect(payload, containsPair('model', 'sface-2021dec-int8'));
      expect((payload['template']! as String).length, 684);
      expect(templateFromBytes(base64.decode(payload['template']! as String)), vector(1));
      expect(payload['consent'], {'id': isA<String>(), 'term_version': 'biometria-v1', 'consented_at': now.toUtc().toIso8601String()});
      final candidates = database.faceCandidates('sface-2021dec-int8');
      expect(candidates.map((c) => c.candidate.id), [faceId]);
      expect(database.faceCandidates('outro'), isEmpty);
    });

    test('o rosto desce da central; fora do formato, ignorado', () {
      final template = base64.encode(templateBytes(vector(5)));
      database.applyPage(userPage(anyId, 5, 'Operador Qualquer', mode: 'any', face: {'model': 'sface-2021dec-int8', 'template': template}), now: now);
      expect(database.userByCode(5)!.hasFace, isTrue);
      database.applyPage(userPage(anyId, 5, 'Operador Qualquer', mode: 'any', face: {'model': 'sface-2021dec-int8', 'template': 'curto'}), now: now);
      expect(database.userByCode(5)!.hasFace, isFalse);
      database.applyPage(userPage(anyId, 5, 'Operador Qualquer', mode: 'any', face: {'model': 'sface-2021dec-int8', 'template': base64.encode(Uint8List(100))}), now: now);
      expect(database.userByCode(5)!.hasFace, isFalse);
    });

    test('entrada pelo rosto: registra a câmera; quem é só PIN não entra assim', () {
      controller.loginWithFace(database.userByCode(3)!);
      expect(controller.operator, isNull);
      expect(controller.notice?.reference, contains('FA824'));
      controller.loginWithFace(database.userByCode(4)!);
      expect(controller.operator?.id, faceId);
      expect(outbox('auth_event').single, allOf(containsPair('method', 'face'), containsPair('purpose', 'login'), containsPair('user_id', faceId)));
      controller.logout();
      controller.faceNotRecognized();
      expect(controller.notice?.reference, contains('FA825'));
    });

    testWidgets('tela: a câmera reconhece e entra; "Entrar de outra forma" volta para o código', (tester) async {
      final enroller = (await tester.runAsync(() => controller.faceEnroller('2', '2468')))!;
      controller.enrollFace(person: database.userByCode(4)!, enroller: enroller, template: vector(1), model: 'sface-2021dec-int8', termVersion: faceTermVersion, consentedAt: now);
      controller.info = null;
      final camera = FakeCamera();
      final face = FaceService(camera: () => camera, engine: () async => FakeEngine(goodRead(vector(1))));
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller, face: face)));
      expect(find.byKey(const Key('face-login')), findsOneWidget);
      await pumpUntil(tester, () => controller.operator != null);
      expect(controller.operator?.id, faceId);
      // A câmera fica ligada para a próxima leitura.
      expect(camera.closed, isFalse);
      expect(face.camera, same(camera));
      controller.logout();
      await tester.pump();
      await tester.tap(find.byKey(const Key('face-other-way')));
      await tester.pump();
      expect(find.byKey(const Key('login-code')), findsOneWidget);
      expect(find.byKey(const Key('face-back')), findsOneWidget);
      // A leitura que começou de novo para na próxima volta.
      await pumpUntil(tester, () => false);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('tela: sem câmera, vai direto para o código e o PIN', (tester) async {
      final face = FaceService(camera: () => FakeCamera(opens: false), engine: () async => FakeEngine(goodRead(vector(1))));
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller, face: face)));
      await pumpUntil(tester, () => find.byKey(const Key('login-code')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('login-code')), findsOneWidget);
      expect(face.unavailable, isTrue);
      await tester.binding.setSurfaceSize(null);
    });

    test('vale da câmera para liberar: uma vez, até 60 s, só da pessoa reconhecida e com a permissão', () async {
      var clock = now;
      final auth = PosAuth(database: database, clock: () => clock);
      // Gerente passa a liberar por qualquer forma (PIN ou câmera).
      database.applyPage(userPage(managerId, 2, 'Gerente Centro', mode: 'any', permissions: const ['sales.sell', 'users.release_login']), now: now);
      final manager = database.userByCode(2)!;
      expect(() => auth.grantFace(database.userByCode(3)!), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA824')));
      auth.grantFace(manager);
      // Outra pessoa com o PIN vazio não aproveita o vale.
      await expectLater(auth.verify('5', ''), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA966')));
      expect((await auth.verify('2', '')).id, managerId);
      // Usado: de novo sem PIN, não.
      await expectLater(auth.verify('2', ''), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA966')));
      auth.grantFace(manager);
      clock = now.add(const Duration(seconds: 61));
      await expectLater(auth.verify('2', ''), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA966')));
      clock = now;
      auth.grantFace(manager);
      await expectLater(auth.verify('2', '', permission: 'sales.return'), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA969')));
      // Só câmera: sem o vale, o PIN não serve.
      auth.grantFace(database.userByCode(4)!);
      expect((await auth.verify('4', '')).id, faceId);
      await expectLater(auth.verify('4', ''), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA820')));
      final faces = outbox('auth_event').where((e) => e['method'] == 'face').toList();
      expect(faces.map((e) => [e['user_id'], e['purpose']]), [[managerId, 'approval'], [faceId, 'approval']]);
    });

    testWidgets('tela: o gerente libera pela câmera a entrada de quem é só câmera', (tester) async {
      database.applyPage(userPage(managerId, 2, 'Gerente Centro', mode: 'any', permissions: const ['sales.sell', 'users.release_login', 'users.biometrics']), now: now);
      final enroller = (await tester.runAsync(() => controller.faceEnroller('2', '2468')))!;
      controller.enrollFace(person: database.userByCode(2)!, enroller: enroller, template: vector(11), model: 'sface-2021dec-int8', termVersion: faceTermVersion, consentedAt: now);
      controller.info = null;
      controller.face = FaceService(camera: FakeCamera.new, engine: () async => FakeEngine(goodRead(vector(11))));
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      // Sem rosto na entrada: vai pelo código, e o código 4 (só câmera) pede a liberação.
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.enterText(find.byKey(const Key('login-code')), '4');
      await tester.pump();
      expect(find.byKey(const Key('release-manager-code')), findsOneWidget);
      await tester.tap(find.byKey(const Key('face-approve')));
      await pumpUntil(tester, () => controller.operator != null);
      expect(controller.operator?.id, faceId);
      final release = outbox('auth_event').where((e) => e['method'] == 'manager_release').single;
      expect(release, containsPair('authorized_by', managerId));
      expect(outbox('auth_event').where((e) => e['method'] == 'face' && e['user_id'] == managerId), hasLength(1));
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('tela: cadastro do rosto com quem autoriza, o termo e a leitura', (tester) async {
      final camera = FakeCamera();
      final face = FaceService(camera: () => camera, engine: () async => FakeEngine(goodRead(vector(7), front: 5)));
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      // Operador já dentro: a câmera da entrada não abre.
      await tester.runAsync(() => controller.login('3', '2468'));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller, face: face)));
      await tester.tap(find.byKey(const Key('face-enroll-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('enroll-enroller-code')), '3');
      await tester.enterText(find.byKey(const Key('enroll-enroller-pin')), '2468');
      await tester.enterText(find.byKey(const Key('enroll-person-code')), '4');
      await tester.tap(find.byKey(const Key('enroll-authorize')));
      await pumpUntil(tester, () => find.byKey(const Key('face-enroll-error')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('face-enroll-error')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('enroll-enroller-code')), '2');
      await tester.enterText(find.byKey(const Key('enroll-enroller-pin')), '2468');
      await tester.tap(find.byKey(const Key('enroll-authorize')));
      await pumpUntil(tester, () => find.byKey(const Key('face-term')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('face-term')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('face-term-continue'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('face-term-agree')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('face-term-continue')));
      await pumpUntil(tester, () => find.byKey(const Key('face-enrolled')).evaluate().isNotEmpty);
      expect(find.byKey(const Key('face-enrolled')), findsOneWidget);
      expect(outbox('face_enrollment').single, containsPair('user_id', faceId));
      expect(database.userByCode(4)!.hasFace, isTrue);
      await tester.binding.setSurfaceSize(null);
    });
  });
}

/// Página da descida com um usuário (para testar o rosto que vem da central).
PullPage userPage(String id, int code, String name, {String? mode, Object? face, List<String> permissions = const ['sales.sell']}) => PullPage(format: 3, until: '9', items: [
    PullItem(type: 'user', id: id, data: {
      'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions,
      'limits': const {}, 'pin_hash': auth_fixture.pin, 'auth_mode': ?mode, 'face': ?face,
    }),
  ]);
