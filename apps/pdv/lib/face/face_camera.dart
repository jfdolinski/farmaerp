import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_lite_camera/flutter_lite_camera.dart';

import 'face_math.dart';

/// Câmera do PDV para o rosto. Os quadros ficam só na memória; nada é gravado.
abstract class FaceCamera {
  /// Abre a primeira câmera do terminal. Falso: não há câmera ou ela não abriu.
  Future<bool> open();

  /// Quadro atual, ou nada se a câmera falhou.
  Future<Frame?> capture();

  /// Imagem ao vivo para a pessoa se enquadrar (espelhada, como num espelho).
  Widget preview();

  Future<void> close();
}

/// Câmera pelo plugin flutter_lite_camera (MIT): quadros RGB na memória e prévia em textura.
class LiteFaceCamera implements FaceCamera {
  final _camera = FlutterLiteCamera();
  int? _texture;
  bool _open = false;

  @override
  Future<bool> open() async {
    if (_open) return true;
    try {
      final devices = await _camera.getDeviceList();
      if (devices.isEmpty || !await _camera.open(0)) return false;
      _texture = await _camera.startPreview();
      _open = true;
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<Frame?> capture() async {
    if (!_open) return null;
    try {
      final frame = await _camera.captureFrame();
      final width = frame['width'] as int? ?? 0;
      final height = frame['height'] as int? ?? 0;
      final data = frame['data'];
      if (width <= 0 || height <= 0 || data is! Uint8List || data.length < width * height * 3) return null;
      return Frame(width: width, height: height, rgb: data);
    } on Object {
      return null;
    }
  }

  @override
  Widget preview() {
    final texture = _texture;
    if (texture == null) return const SizedBox.shrink();
    return Transform.flip(flipX: true, child: _camera.buildPreview(texture));
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    try {
      await _camera.stopPreview();
      await _camera.release();
    } on Object {
      // Câmera já solta.
    }
    _texture = null;
  }
}
