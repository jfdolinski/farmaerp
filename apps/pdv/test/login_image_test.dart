import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farmaerp_pdv/ui/login_backdrop.dart';
import 'package:farmaerp_pdv/ui/login_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PNG de 1 × 1 ponto, válido.
final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class FakeLoginImageApi implements LoginImageApi {
  String? digest;
  Uint8List bytes = Uint8List(0);
  bool offline = false;
  int downloads = 0;

  @override
  Future<String?> current() async {
    if (offline) throw const SocketException('sem internet');
    return digest;
  }

  @override
  Future<Uint8List> download() async {
    downloads += 1;
    return bytes;
  }

  Future<void> publish(List<int> content) async {
    bytes = Uint8List.fromList(content);
    digest = await sha256Hex(content);
  }
}

void main() {
  late Directory directory;
  late FakeLoginImageApi api;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tela-entrada-');
    api = FakeLoginImageApi();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  LoginImageStore store() => LoginImageStore(directory: directory, api: api);

  group('imagem da tela de entrada guardada no caixa', () {
    test('baixa quando a central tem imagem, guarda e abre de novo sem internet', () async {
      await api.publish(pixel);
      final first = store();
      var notified = 0;
      first.addListener(() => notified += 1);
      await first.refresh();
      expect(first.bytes, pixel);
      expect(first.sha256, api.digest);
      expect(notified, 1);

      // Outra abertura do caixa, sem internet: a imagem continua.
      api.offline = true;
      final second = store();
      await second.load();
      expect(second.bytes, pixel);
      await second.refresh();
      expect(second.bytes, pixel);
    });

    test('só baixa de novo quando o resumo muda', () async {
      await api.publish(pixel);
      final s = store();
      await s.refresh();
      await s.refresh();
      expect(api.downloads, 1);
      final other = [...pixel, 0];
      await api.publish(other);
      await s.refresh();
      expect(api.downloads, 2);
      expect(s.bytes, other);
    });

    test('a plataforma tirou a imagem: o caixa apaga a guardada e volta para a cor', () async {
      await api.publish(pixel);
      final s = store();
      await s.refresh();
      api.digest = null;
      await s.refresh();
      expect(s.bytes, isNull);
      final reopened = store();
      await reopened.load();
      expect(reopened.bytes, isNull);
      expect(directory.listSync(), isEmpty);
    });

    test('arquivo que não confere com o resumo não é usado', () async {
      await api.publish(pixel);
      api.bytes = Uint8List.fromList([...pixel, 1]);
      final s = store();
      await s.refresh();
      expect(s.bytes, isNull);
      expect(directory.listSync(), isEmpty);
    });

    test('arquivo maior que 3 MB não é guardado', () async {
      final big = Uint8List(loginImageMaxBytes + 1);
      await api.publish(big);
      final s = store();
      await s.refresh();
      expect(s.bytes, isNull);
    });

    test('arquivo guardado alterado no disco é ignorado ao abrir', () async {
      await api.publish(pixel);
      await store().refresh();
      final saved = directory.listSync().whereType<File>().firstWhere((file) => file.path.endsWith('.bin'));
      saved.writeAsBytesSync([...pixel, 9]);
      final reopened = store();
      await reopened.load();
      expect(reopened.bytes, isNull);
    });
  });

  group('tela de entrada com a imagem', () {
    Future<void> pump(WidgetTester tester, {LoginImageStore? image, Size size = const Size(1280, 800), bool wide = false}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoginBackdrop(image: image, wide: wide, child: const Text('campos de entrada')),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('sem imagem fica a cor; o cartão à direita, no meio da altura', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('login-backdrop-brand')), findsOneWidget);
      expect(find.byKey(const Key('login-backdrop-image')), findsNothing);
      final card = tester.getRect(find.byKey(const Key('login-card')));
      expect(card.center.dx, greaterThan(1280 / 2));
      expect(card.center.dy, closeTo(800 / 2, 2));
      expect(card.width, closeTo(420, 0.5));
      expect(find.descendant(of: find.byKey(const Key('login-card')), matching: find.text('campos de entrada')), findsOneWidget);
    });

    testWidgets('com imagem guardada, ela cobre a tela por trás do cartão', (tester) async {
      await api.publish(pixel);
      final s = store();
      await tester.runAsync(s.refresh);
      await pump(tester, image: s);
      final image = tester.getRect(find.byKey(const Key('login-backdrop-image')));
      expect(image.size, const Size(1280, 800));
      final decoration = tester.widget<Container>(find.byKey(const Key('login-card'))).decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(18));
      expect(decoration.boxShadow, isNotEmpty);
    });

    testWidgets('em tela estreita o cartão vai para o centro; com a câmera ele fica mais largo', (tester) async {
      await pump(tester, size: const Size(600, 900));
      final card = tester.getRect(find.byKey(const Key('login-card')));
      expect(card.center.dx, closeTo(300, 2));
      await pump(tester, size: const Size(1400, 900), wide: true);
      expect(tester.getRect(find.byKey(const Key('login-card'))).width, closeTo(540, 0.5));
    });
  });
}
