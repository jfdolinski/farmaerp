import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'face_math.dart';

/// Motor do rosto: acha os rostos, mede a prova de vida e tira o código numérico. Fica atrás desta
/// interface para poder trocar de modelo (ou por um SDK comercial) sem mexer no resto do PDV.
abstract class FaceEngine {
  /// Nome do modelo do código do rosto: só se comparam códigos do mesmo modelo.
  String get model;

  /// Rostos no quadro, nas coordenadas do quadro, do mais provável para o menos.
  Future<List<FaceBox>> detect(Frame frame);

  /// Prova de vida: diferença entre "real" e "falso" (acima de 0 é real).
  Future<double> liveness(Frame frame, FaceBox face);

  /// Código numérico do rosto (128 números, norma 1).
  Future<Float32List> embed(Frame frame, FaceBox face);

  Future<void> close();
}

/// Modelos abertos rodando no próprio PDV: YuNet (detecção, MIT), MiniFASNet (prova de vida,
/// Apache 2.0) e SFace int8 (reconhecimento, Apache 2.0 na conversão da OpenCV).
class OnnxFaceEngine implements FaceEngine {
  OnnxFaceEngine._(this._detector, this._liveness, this._recognizer);

  static const modelName = 'sface-2021dec-int8';

  final OrtSession _detector;
  final OrtSession _liveness;
  final OrtSession _recognizer;

  @override
  String get model => modelName;

  static Future<OnnxFaceEngine> open() async {
    final ort = OnnxRuntime();
    final detector = await ort.createSessionFromAsset('assets/face/face_detection_yunet_2023mar.onnx');
    final liveness = await ort.createSessionFromAsset('assets/face/face_antispoof_minifas_int8.onnx');
    final recognizer = await ort.createSessionFromAsset('assets/face/face_recognition_sface_2021dec_int8.onnx');
    return OnnxFaceEngine._(detector, liveness, recognizer);
  }

  Future<Map<String, Float32List>> _run(OrtSession session, String inputName, Float32List input, List<int> shape) async {
    final tensor = await OrtValue.fromList(input, shape);
    try {
      final outputs = await session.run({inputName: tensor});
      final result = <String, Float32List>{};
      for (final entry in outputs.entries) {
        final values = await entry.value.asFlattenedList();
        result[entry.key] = Float32List.fromList([for (final v in values) (v as num).toDouble()]);
        await entry.value.dispose();
      }
      return result;
    } finally {
      await tensor.dispose();
    }
  }

  @override
  Future<List<FaceBox>> detect(Frame frame) async {
    final prepared = yunetInput(frame);
    final outputs = await _run(_detector, 'input', prepared.input, const [1, 3, yunetSize, yunetSize]);
    return [for (final face in decodeYunet(outputs)) face.scaled(prepared.scale)];
  }

  @override
  Future<double> liveness(Frame frame, FaceBox face) async {
    final outputs = await _run(_liveness, 'input', livenessInput(frame, face), const [1, 3, livenessSize, livenessSize]);
    final logits = outputs['output']!;
    return logits[0] - logits[1];
  }

  @override
  Future<Float32List> embed(Frame frame, FaceBox face) async {
    final outputs = await _run(_recognizer, 'data', sfaceInput(frame, face), const [1, 3, sfaceSize, sfaceSize]);
    return normalized(outputs['fc1']!);
  }

  @override
  Future<void> close() async {
    await _detector.close();
    await _liveness.close();
    await _recognizer.close();
  }
}
