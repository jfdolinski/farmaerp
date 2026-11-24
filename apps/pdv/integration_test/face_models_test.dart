import 'dart:typed_data';

import 'package:farmaerp_pdv/face/face_engine.dart';
import 'package:farmaerp_pdv/face/face_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Roda os três modelos de verdade no Windows (sem câmera e sem rosto de pessoa): carregam, as
/// entradas e saídas batem e o tempo cabe na leitura. Uso: flutter test integration_test -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('modelos do rosto rodam no terminal', (tester) async {
    final engine = await OnnxFaceEngine.open();
    try {
      // Quadro cinza com um degradê: não tem rosto.
      final rgb = Uint8List(640 * 480 * 3);
      for (var i = 0; i < 640 * 480; i += 1) {
        rgb[i * 3] = (i % 640) * 255 ~/ 640;
        rgb[i * 3 + 1] = 128;
        rgb[i * 3 + 2] = (i ~/ 640) * 255 ~/ 480;
      }
      final frame = Frame(width: 640, height: 480, rgb: rgb);
      final watch = Stopwatch()..start();
      final faces = await engine.detect(frame);
      final detectMs = watch.elapsedMilliseconds;
      expect(faces, isEmpty);

      // Caixa e pontos de um rosto de frente, no meio do quadro (só para rodar os modelos).
      final box = FaceBox(
        x: 220, y: 140, width: 200, height: 200, score: 1,
        landmarks: [for (final p in sfaceTemplate) FacePoint(220 + p.x * 200 / 112, 140 + p.y * 200 / 112)],
      );
      watch.reset();
      final liveness = await engine.liveness(frame, box);
      final livenessMs = watch.elapsedMilliseconds;
      expect(liveness.isFinite, isTrue);
      watch.reset();
      final embedding = await engine.embed(frame, box);
      final embedMs = watch.elapsedMilliseconds;
      expect(embedding, hasLength(128));
      final norm = embedding.fold<double>(0, (sum, v) => sum + v * v);
      expect(norm, closeTo(1, 1e-3));
      // ignore: avoid_print
      print('TEMPOS detecção ${detectMs}ms · prova de vida ${livenessMs}ms · código ${embedMs}ms');
    } finally {
      await engine.close();
    }
  });
}
