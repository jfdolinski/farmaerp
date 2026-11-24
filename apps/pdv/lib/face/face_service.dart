import 'package:flutter/foundation.dart';

import 'face_camera.dart';
import 'face_engine.dart';

/// Versão do termo de consentimento da biometria. Mudou o texto, muda a versão.
const faceTermVersion = 'biometria-v1';

/// Termo de consentimento para o uso do rosto (LGPD, dado pessoal sensível). Rascunho: precisa da
/// revisão do jurídico ou do encarregado de dados da rede antes de produção.
const faceTermText = '''
Para entrar no PDV e liberar operações pelo rosto, o sistema guarda um código numérico calculado a partir do seu rosto. A foto não é guardada em lugar nenhum: a imagem da câmera fica só na memória do terminal, durante a leitura.

O código serve só para identificar você no PDV das lojas em que você trabalha e fica guardado de forma protegida. Ele não é usado para outra finalidade nem compartilhado com terceiros.

O uso do rosto é opcional. Você pode continuar entrando com o PIN e pode pedir ao gerente, a qualquer momento, que o rosto seja apagado, sem prejuízo.

Ao confirmar, você declara que leu este termo e concorda com o uso do seu rosto para essa finalidade.''';

/// Rosto no PDV: carrega o motor e abre a câmera só enquanto uma tela precisa dela (a luz da câmera
/// não fica acesa o dia todo). Sem câmera, sem modelo ou com falha, o PDV segue com o PIN e a
/// liberação do gerente.
class FaceService extends ChangeNotifier {
  FaceService({required FaceCamera Function() camera, required Future<FaceEngine> Function() engine})
    : _cameraFactory = camera,
      _engineFactory = engine;

  final FaceCamera Function() _cameraFactory;
  final Future<FaceEngine> Function() _engineFactory;

  FaceCamera? camera;
  FaceEngine? engine;
  bool _starting = false;

  /// A última tentativa de abrir a câmera ou o motor falhou.
  bool unavailable = false;

  /// Câmera aberta e modelos carregados.
  bool get ready => camera != null && engine != null;

  Future<bool> start() async {
    if (ready) return true;
    if (_starting) return false;
    _starting = true;
    try {
      engine ??= await _engineFactory();
      final opened = _cameraFactory();
      if (await opened.open()) camera = opened;
    } on Object {
      engine = null;
    } finally {
      unavailable = !ready;
      _starting = false;
      notifyListeners();
    }
    return ready;
  }

  /// A câmera falhou durante o uso: o PDV volta para o PIN e a liberação do gerente.
  Future<void> cameraLost() async {
    unavailable = true;
    await closeCamera();
  }

  /// A tela que usava a câmera fechou: apaga a câmera e mantém o motor carregado.
  Future<void> closeCamera() async {
    final current = camera;
    camera = null;
    notifyListeners();
    await current?.close();
  }

  Future<void> stop() async {
    await camera?.close();
    camera = null;
    await engine?.close();
    engine = null;
    notifyListeners();
  }
}
