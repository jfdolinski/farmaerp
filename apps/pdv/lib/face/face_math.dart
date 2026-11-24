import 'dart:math' as math;
import 'dart:typed_data';

/// Quadro da câmera na memória: RGB, 3 bytes por pixel. Nunca é gravado em disco.
class Frame {
  const Frame({required this.width, required this.height, required this.rgb});

  final int width;
  final int height;
  final Uint8List rgb;
}

class FacePoint {
  const FacePoint(this.x, this.y);

  final double x;
  final double y;
}

/// Rosto achado no quadro: caixa e os 5 pontos (olho direito, olho esquerdo, ponta do nariz,
/// canto direito e canto esquerdo da boca, do ponto de vista da pessoa), nas coordenadas do quadro.
class FaceBox {
  const FaceBox({required this.x, required this.y, required this.width, required this.height, required this.score, required this.landmarks});

  final double x;
  final double y;
  final double width;
  final double height;
  final double score;
  final List<FacePoint> landmarks;

  double get area => width * height;

  FaceBox scaled(double factor) => FaceBox(
    x: x / factor,
    y: y / factor,
    width: width / factor,
    height: height / factor,
    score: score,
    landmarks: [for (final p in landmarks) FacePoint(p.x / factor, p.y / factor)],
  );
}

/// Detector YuNet (2023mar): entrada 640x640, BGR, valores de 0 a 255, sem normalização.
const yunetSize = 640;

/// Coloca o quadro no canto do quadrado 640x640 do detector, mantendo a proporção. Devolve a entrada
/// (NCHW, BGR) e a escala usada (para voltar às coordenadas do quadro).
({Float32List input, double scale}) yunetInput(Frame frame) {
  final scale = math.min(yunetSize / frame.width, yunetSize / frame.height);
  final width = (frame.width * scale).floor();
  final height = (frame.height * scale).floor();
  const plane = yunetSize * yunetSize;
  final input = Float32List(3 * plane);
  for (var y = 0; y < height; y += 1) {
    final sy = math.min(frame.height - 1, (y / scale).floor());
    for (var x = 0; x < width; x += 1) {
      final sx = math.min(frame.width - 1, (x / scale).floor());
      final source = (sy * frame.width + sx) * 3;
      final target = y * yunetSize + x;
      input[target] = frame.rgb[source + 2].toDouble(); // B
      input[plane + target] = frame.rgb[source + 1].toDouble(); // G
      input[2 * plane + target] = frame.rgb[source].toDouble(); // R
    }
  }
  return (input: input, scale: scale);
}

/// Decodifica as 12 saídas do YuNet (cls, obj, bbox e kps em 3 escalas) em rostos, com supressão
/// de sobrepostos. Coordenadas na entrada 640x640.
List<FaceBox> decodeYunet(
  Map<String, Float32List> outputs, {
  double scoreThreshold = 0.85,
  double nmsThreshold = 0.3,
  int size = yunetSize,
}) {
  final found = <FaceBox>[];
  for (final stride in const [8, 16, 32]) {
    final cls = outputs['cls_$stride']!;
    final obj = outputs['obj_$stride']!;
    final bbox = outputs['bbox_$stride']!;
    final kps = outputs['kps_$stride']!;
    final cols = size ~/ stride;
    final rows = size ~/ stride;
    for (var r = 0; r < rows; r += 1) {
      for (var c = 0; c < cols; c += 1) {
        final index = r * cols + c;
        final score = math.sqrt(cls[index].clamp(0.0, 1.0) * obj[index].clamp(0.0, 1.0));
        if (score < scoreThreshold) continue;
        final cx = (c + bbox[index * 4]) * stride;
        final cy = (r + bbox[index * 4 + 1]) * stride;
        final w = math.exp(bbox[index * 4 + 2]) * stride;
        final h = math.exp(bbox[index * 4 + 3]) * stride;
        found.add(FaceBox(
          x: cx - w / 2,
          y: cy - h / 2,
          width: w,
          height: h,
          score: score,
          landmarks: [
            for (var n = 0; n < 5; n += 1)
              FacePoint((kps[index * 10 + 2 * n] + c) * stride, (kps[index * 10 + 2 * n + 1] + r) * stride),
          ],
        ));
      }
    }
  }
  found.sort((a, b) => b.score.compareTo(a.score));
  final kept = <FaceBox>[];
  for (final face in found) {
    if (kept.every((other) => iou(face, other) <= nmsThreshold)) kept.add(face);
  }
  return kept;
}

double iou(FaceBox a, FaceBox b) {
  final x1 = math.max(a.x, b.x);
  final y1 = math.max(a.y, b.y);
  final x2 = math.min(a.x + a.width, b.x + b.width);
  final y2 = math.min(a.y + a.height, b.y + b.height);
  final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
  final union = a.area + b.area - inter;
  return union <= 0 ? 0 : inter / union;
}

/// Pontos de referência do SFace (112x112), na mesma ordem dos pontos do YuNet.
const sfaceTemplate = [
  FacePoint(38.2946, 51.6963),
  FacePoint(73.5318, 51.5014),
  FacePoint(56.0252, 71.7366),
  FacePoint(41.5493, 92.3655),
  FacePoint(70.7299, 92.2041),
];
const sfaceSize = 112;

/// Semelhança (escala, rotação e deslocamento, sem espelhar) que leva [src] o mais perto possível de
/// [dst], por mínimos quadrados. Devolve a matriz 2x3 [a, -b, tx, b, a, ty].
List<double> similarityTransform(List<FacePoint> src, List<FacePoint> dst) {
  final n = src.length;
  var msx = 0.0, msy = 0.0, mdx = 0.0, mdy = 0.0;
  for (var i = 0; i < n; i += 1) {
    msx += src[i].x;
    msy += src[i].y;
    mdx += dst[i].x;
    mdy += dst[i].y;
  }
  msx /= n;
  msy /= n;
  mdx /= n;
  mdy /= n;
  var dot = 0.0, cross = 0.0, norm = 0.0;
  for (var i = 0; i < n; i += 1) {
    final px = src[i].x - msx, py = src[i].y - msy;
    final qx = dst[i].x - mdx, qy = dst[i].y - mdy;
    dot += px * qx + py * qy;
    cross += px * qy - py * qx;
    norm += px * px + py * py;
  }
  final a = norm == 0 ? 1.0 : dot / norm;
  final b = norm == 0 ? 0.0 : cross / norm;
  final tx = mdx - (a * msx - b * msy);
  final ty = mdy - (b * msx + a * msy);
  return [a, -b, tx, b, a, ty];
}

/// Rosto alinhado 112x112 para o SFace: NCHW, RGB, valores de 0 a 255.
Float32List sfaceInput(Frame frame, FaceBox face) {
  final m = similarityTransform(face.landmarks, sfaceTemplate);
  // Inversa da semelhança: de cada pixel do rosto alinhado volta ao quadro.
  final a = m[0], b = m[3], det = a * a + b * b;
  const plane = sfaceSize * sfaceSize;
  final input = Float32List(3 * plane);
  for (var v = 0; v < sfaceSize; v += 1) {
    for (var u = 0; u < sfaceSize; u += 1) {
      final dx = u - m[2], dy = v - m[5];
      final sx = (a * dx + b * dy) / det;
      final sy = (-b * dx + a * dy) / det;
      final target = v * sfaceSize + u;
      for (var channel = 0; channel < 3; channel += 1) {
        input[channel * plane + target] = _bilinear(frame, sx, sy, channel, border: false);
      }
    }
  }
  return input;
}

/// Prova de vida (MiniFASNet): recorte quadrado 1,5 vez o rosto, bordas espelhadas, 128x128, RGB
/// de 0 a 1, NCHW.
const livenessSize = 128;

Float32List livenessInput(Frame frame, FaceBox face, {double expansion = 1.5}) {
  final maxDim = math.max(face.width, face.height);
  final cx = face.x + face.width / 2;
  final cy = face.y + face.height / 2;
  final size = maxDim * expansion;
  final x0 = (cx - size / 2).floorToDouble();
  final y0 = (cy - size / 2).floorToDouble();
  const plane = livenessSize * livenessSize;
  final input = Float32List(3 * plane);
  final step = size / livenessSize;
  for (var v = 0; v < livenessSize; v += 1) {
    for (var u = 0; u < livenessSize; u += 1) {
      final sx = x0 + (u + 0.5) * step - 0.5;
      final sy = y0 + (v + 0.5) * step - 0.5;
      final target = v * livenessSize + u;
      for (var channel = 0; channel < 3; channel += 1) {
        input[channel * plane + target] = _bilinear(frame, sx, sy, channel, border: true) / 255;
      }
    }
  }
  return input;
}

/// Índice dentro da imagem com espelhamento sem repetir a borda (como BORDER_REFLECT_101).
int reflect101(int index, int length) {
  if (length == 1) return 0;
  var i = index;
  while (i < 0 || i >= length) {
    if (i < 0) i = -i;
    if (i >= length) i = 2 * length - 2 - i;
  }
  return i;
}

double _bilinear(Frame frame, double x, double y, int channel, {required bool border}) {
  final x0 = x.floor(), y0 = y.floor();
  final fx = x - x0, fy = y - y0;
  double at(int px, int py) {
    if (border) {
      px = reflect101(px, frame.width);
      py = reflect101(py, frame.height);
    } else if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) {
      return 0;
    }
    return frame.rgb[(py * frame.width + px) * 3 + channel].toDouble();
  }

  return at(x0, y0) * (1 - fx) * (1 - fy) +
      at(x0 + 1, y0) * fx * (1 - fy) +
      at(x0, y0 + 1) * (1 - fx) * fy +
      at(x0 + 1, y0 + 1) * fx * fy;
}

/// Vetor com norma 1 (o código do rosto é comparado pelo cosseno).
Float32List normalized(List<double> vector) {
  var sum = 0.0;
  for (final v in vector) {
    sum += v * v;
  }
  final norm = math.sqrt(sum);
  return Float32List.fromList([for (final v in vector) norm == 0 ? 0 : v / norm]);
}

double cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / math.sqrt(na * nb);
}

/// Média dos códigos (já normalizados), normalizada de novo: o código guardado no cadastro.
Float32List averageTemplate(List<List<double>> embeddings) {
  final sum = List<double>.filled(embeddings.first.length, 0);
  for (final e in embeddings) {
    final n = normalized(e);
    for (var i = 0; i < sum.length; i += 1) {
      sum[i] += n[i];
    }
  }
  return normalized(sum);
}

/// Quanto o rosto está virado para o lado: deslocamento do nariz em relação ao meio dos olhos,
/// medido na distância entre os olhos. Perto de 0 é de frente.
double yawOf(FaceBox face) {
  final right = face.landmarks[0], left = face.landmarks[1], nose = face.landmarks[2];
  final eyes = (left.x - right.x).abs();
  if (eyes < 1) return 0;
  return (nose.x - (left.x + right.x) / 2) / eyes;
}

/// Código do rosto para guardar e mandar: 128 float32 em little-endian (512 bytes).
Uint8List templateBytes(List<double> template) {
  final data = ByteData(template.length * 4);
  for (var i = 0; i < template.length; i += 1) {
    data.setFloat32(i * 4, template[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Float32List templateFromBytes(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return Float32List.fromList([for (var i = 0; i < bytes.length ~/ 4; i += 1) data.getFloat32(i * 4, Endian.little)]);
}
