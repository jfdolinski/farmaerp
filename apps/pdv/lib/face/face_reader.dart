import 'dart:typed_data';

import 'face_camera.dart';
import 'face_engine.dart';
import 'face_math.dart';

/// Etapas da leitura do rosto: de frente (com a prova de vida), o desafio de virar o rosto e a
/// volta para a frente. Uma foto ou um vídeo na tela não passa pela prova de vida; uma foto
/// impressa não vira o rosto.
enum FaceStage { front, turn, back, done, failed }

/// O que o motor viu num quadro.
class FaceObservation {
  const FaceObservation({required this.faces, required this.frameWidth, this.face, this.liveness, this.embedding});

  final int faces;
  final int frameWidth;
  final FaceBox? face;
  final double? liveness;
  final Float32List? embedding;
}

/// Regras da leitura, sem câmera nem modelo: recebe o que foi visto e diz o que pedir à pessoa.
class FaceReader {
  FaceReader({
    this.frontFrames = 3,
    this.timeout = const Duration(seconds: 20),
    this.livenessThreshold = 0.0,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _startedAt = _clock();
  }

  /// Quadros de frente, com prova de vida, para formar o código.
  final int frontFrames;
  final Duration timeout;
  final double livenessThreshold;
  final DateTime Function() _clock;
  late final DateTime _startedAt;

  static const frontYaw = 0.15;
  static const turnYaw = 0.30;
  static const minFaceShare = 0.18;
  static const sameFace = 0.6;
  static const maxSpoofFrames = 3;

  FaceStage stage = FaceStage.front;
  String message = 'Olhe para a câmera.';
  final _embeddings = <Float32List>[];
  int _spoofFrames = 0;
  Float32List? result;

  bool get finished => stage == FaceStage.done || stage == FaceStage.failed;

  /// Nestas etapas o leitor quer a prova de vida e o código do quadro.
  bool get wantsLiveness => stage == FaceStage.front || stage == FaceStage.back;
  bool get wantsEmbedding => stage == FaceStage.front || stage == FaceStage.back;

  void _fail(String text) {
    stage = FaceStage.failed;
    message = text;
  }

  /// A câmera (ou o motor) parou no meio da leitura.
  bool cameraProblem = false;

  void cameraFailed() {
    cameraProblem = true;
    _fail('A câmera parou de responder. Entre de outra forma.');
  }

  void observe(FaceObservation seen) {
    if (finished) return;
    if (_clock().difference(_startedAt) > timeout) {
      return _fail('Tempo esgotado. Tente de novo ou entre de outra forma.');
    }
    if (seen.faces == 0 || seen.face == null) {
      message = stage == FaceStage.front ? 'Olhe para a câmera.' : 'Não perca a câmera de vista.';
      return;
    }
    if (seen.faces > 1) {
      message = 'Só uma pessoa na frente da câmera.';
      return;
    }
    final face = seen.face!;
    if (face.width < seen.frameWidth * minFaceShare) {
      message = 'Chegue mais perto da câmera.';
      return;
    }
    final yaw = yawOf(face);
    switch (stage) {
      case FaceStage.front:
        if (yaw.abs() > frontYaw) {
          message = 'Olhe de frente para a câmera.';
          return;
        }
        if (!_live(seen)) return;
        final embedding = seen.embedding;
        if (embedding == null) return;
        // Outra pessoa entrou no lugar: recomeça.
        if (_embeddings.isNotEmpty && cosine(_embeddings.first, embedding) < sameFace) _embeddings.clear();
        _embeddings.add(embedding);
        if (_embeddings.length >= frontFrames) {
          stage = FaceStage.turn;
          message = 'Agora vire o rosto devagar para um lado.';
        } else {
          message = 'Fique parado, olhando para a câmera.';
        }
      case FaceStage.turn:
        if (yaw.abs() >= turnYaw) {
          stage = FaceStage.back;
          message = 'Isso. Volte a olhar de frente.';
        }
      case FaceStage.back:
        if (yaw.abs() > frontYaw) return;
        if (!_live(seen)) return;
        final embedding = seen.embedding;
        if (embedding == null) return;
        final template = averageTemplate(_embeddings);
        if (cosine(template, embedding) < sameFace) {
          return _fail('O rosto mudou durante a leitura. Tente de novo.');
        }
        result = averageTemplate([..._embeddings, embedding]);
        stage = FaceStage.done;
        message = 'Rosto lido.';
      case FaceStage.done:
      case FaceStage.failed:
        return;
    }
  }

  bool _live(FaceObservation seen) {
    final liveness = seen.liveness;
    if (liveness == null) return false;
    if (liveness < livenessThreshold) {
      _spoofFrames += 1;
      if (_spoofFrames >= maxSpoofFrames) {
        _fail('Não foi possível confirmar que há uma pessoa presente. Entre de outra forma.');
      } else {
        message = 'Fique parado, olhando para a câmera.';
      }
      return false;
    }
    _spoofFrames = 0;
    return true;
  }
}

/// Lê o rosto pela câmera até o leitor terminar (ou a tela cancelar). Os quadros ficam só na
/// memória e são descartados a cada volta.
Future<Float32List?> readFace({
  required FaceCamera camera,
  required FaceEngine engine,
  required FaceReader reader,
  required void Function() onUpdate,
  required bool Function() cancelled,
  Duration pause = const Duration(milliseconds: 60),
}) async {
  while (!reader.finished && !cancelled()) {
    final frame = await camera.capture();
    if (frame == null) {
      reader.cameraFailed();
      break;
    }
    try {
      final faces = await engine.detect(frame);
      final face = faces.length == 1 ? faces.first : null;
      double? liveness;
      Float32List? embedding;
      if (face != null && reader.wantsLiveness) liveness = await engine.liveness(frame, face);
      if (face != null && reader.wantsEmbedding && (liveness ?? 0) >= reader.livenessThreshold) {
        embedding = await engine.embed(frame, face);
      }
      reader.observe(FaceObservation(
        faces: faces.length,
        frameWidth: frame.width,
        face: faces.isEmpty ? null : faces.first,
        liveness: liveness,
        embedding: embedding,
      ));
    } on Object {
      reader.cameraFailed();
    }
    onUpdate();
    if (!reader.finished) await Future<void>.delayed(pause);
  }
  onUpdate();
  return reader.stage == FaceStage.done ? reader.result : null;
}

/// Quem é este rosto entre os cadastrados: o mais parecido, se passar do limite e estiver claramente
/// à frente do segundo.
({T match, double score})? bestFaceMatch<T>(
  List<double> embedding,
  List<({T candidate, List<double> template})> candidates, {
  double threshold = 0.40,
  double margin = 0.05,
}) {
  ({T match, double score})? best;
  var second = -1.0;
  for (final item in candidates) {
    final score = cosine(embedding, item.template);
    if (best == null || score > best.score) {
      if (best != null) second = best.score;
      best = (match: item.candidate, score: score);
    } else if (score > second) {
      second = score;
    }
  }
  if (best == null || best.score < threshold || best.score - second < margin) return null;
  return best;
}
