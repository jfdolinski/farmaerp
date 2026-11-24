import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../local/local_database.dart';
import '../pos/pos_auth.dart';
import '../pos/pos_controller.dart';
import '../ui/caps.dart';
import 'face_reader.dart';
import 'face_service.dart';

/// Imagem da câmera com a mensagem da leitura por baixo.
class _CameraView extends StatelessWidget {
  const _CameraView({required this.face, required this.message, required this.failed});

  final FaceService face;
  final String message;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final camera = face.camera;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ColoredBox(
              color: Colors.black,
              child: camera == null ? const SizedBox.shrink() : camera.preview(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          key: const Key('face-message'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: failed ? Theme.of(context).colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}

/// Tela inicial com a câmera: reconhece sozinha quem olha para ela (prova de vida e o desafio de
/// virar o rosto) e entra. "Entrar de outra forma" volta para o código e o PIN.
class FaceLoginPanel extends StatefulWidget {
  const FaceLoginPanel({super.key, required this.controller, required this.face, required this.onOtherWay});

  final PosController controller;
  final FaceService face;
  final VoidCallback onOtherWay;

  @override
  State<FaceLoginPanel> createState() => _FaceLoginPanelState();
}

class _FaceLoginPanelState extends State<FaceLoginPanel> {
  FaceReader _reader = FaceReader();
  bool _closed = false;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _closed = true;
    widget.face.closeCamera();
    super.dispose();
  }

  Future<void> _start() async {
    if (_reading) return;
    if (!await widget.face.start()) {
      if (mounted) widget.onOtherWay();
      return;
    }
    if (!mounted) return;
    setState(() {
      _reader = FaceReader();
      _reading = true;
    });
    final engine = widget.face.engine!;
    final result = await readFace(
      camera: widget.face.camera!,
      engine: engine,
      reader: _reader,
      onUpdate: () {
        if (mounted) setState(() {});
      },
      cancelled: () => _closed,
    );
    if (_closed) return;
    _reading = false;
    if (_reader.cameraProblem) {
      await widget.face.cameraLost();
      if (mounted) widget.onOtherWay();
      return;
    }
    if (result != null) {
      final found = bestFaceMatch<LocalUser>(result, widget.controller.database.faceCandidates(engine.model));
      if (found == null) {
        widget.controller.faceNotRecognized();
      } else {
        widget.controller.loginWithFace(found.match);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final failed = _reader.stage == FaceStage.failed;
    return Column(
      key: const Key('face-login'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CameraView(face: widget.face, message: _reader.message, failed: failed),
        const SizedBox(height: 16),
        if (!_reading)
          FilledButton(
            key: const Key('face-retry'),
            onPressed: _start,
            child: const Text('Tentar de novo pela câmera'),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('face-other-way'),
          onPressed: widget.onOtherWay,
          child: const Text('Entrar de outra forma'),
        ),
      ],
    );
  }
}

/// Cadastro do rosto no PDV: quem autoriza (código e PIN, com "Cadastrar o rosto no PDV"), a
/// pessoa, o termo de consentimento e a leitura. Só o código numérico do rosto é guardado.
Future<void> showFaceEnrollment(BuildContext context, PosController controller, FaceService face) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _FaceEnrollmentDialog(controller: controller, face: face),
  );
}

enum _EnrollStep { authorize, term, read, done }

class _FaceEnrollmentDialog extends StatefulWidget {
  const _FaceEnrollmentDialog({required this.controller, required this.face});

  final PosController controller;
  final FaceService face;

  @override
  State<_FaceEnrollmentDialog> createState() => _FaceEnrollmentDialogState();
}

class _FaceEnrollmentDialogState extends State<_FaceEnrollmentDialog> {
  final _enrollerCode = TextEditingController();
  final _enrollerPin = TextEditingController();
  final _personCode = TextEditingController();
  _EnrollStep _step = _EnrollStep.authorize;
  LocalUser? _enroller;
  LocalUser? _person;
  bool _agreed = false;
  DateTime? _consentedAt;
  String? _error;
  FaceReader _reader = FaceReader(frontFrames: 5);
  bool _closed = false;
  bool _reading = false;

  @override
  void dispose() {
    _closed = true;
    _enrollerCode.dispose();
    _enrollerPin.dispose();
    _personCode.dispose();
    widget.face.closeCamera();
    super.dispose();
  }

  Future<void> _authorize() async {
    final enroller = await widget.controller.faceEnroller(_enrollerCode.text, _enrollerPin.text);
    _enrollerPin.clear();
    final person = widget.controller.auth.userByCodeText(_personCode.text);
    setState(() {
      _error = enroller == null
          ? widget.controller.notice?.message
          : person == null
          ? 'Código da pessoa não encontrado neste terminal.'
          : null;
      if (enroller != null && person != null) {
        _enroller = enroller;
        _person = person;
        _step = _EnrollStep.term;
      }
    });
  }

  Future<void> _read() async {
    if (_reading) return;
    setState(() {
      _step = _EnrollStep.read;
      _error = null;
      _reader = FaceReader(frontFrames: 5);
      _reading = true;
    });
    if (!await widget.face.start()) {
      setState(() {
        _reading = false;
        _error = 'A câmera não abriu. Confira se ela está ligada ao terminal.';
      });
      return;
    }
    final engine = widget.face.engine!;
    final result = await readFace(
      camera: widget.face.camera!,
      engine: engine,
      reader: _reader,
      onUpdate: () {
        if (mounted) setState(() {});
      },
      cancelled: () => _closed,
    );
    if (_closed) return;
    _reading = false;
    if (result != null) {
      widget.controller.enrollFace(
        person: _person!,
        enroller: _enroller!,
        template: result,
        model: engine.model,
        termVersion: faceTermVersion,
        consentedAt: _consentedAt!,
      );
      await widget.face.closeCamera();
      if (mounted) setState(() => _step = _EnrollStep.done);
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    return AlertDialog(
      key: const Key('face-enrollment'),
      title: const Text('Cadastrar rosto'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: switch (_step) {
              _EnrollStep.authorize => [
                const Text('Quem autoriza o cadastro (o gerente) digita o código e o PIN.'),
                TextField(
                  key: const Key('enroll-enroller-code'),
                  controller: _enrollerCode,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Código de quem autoriza'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                TextField(
                  key: const Key('enroll-enroller-pin'),
                  controller: _enrollerPin,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'PIN de quem autoriza'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                ),
                TextField(
                  key: const Key('enroll-person-code'),
                  controller: _personCode,
                  decoration: const InputDecoration(labelText: 'Código da pessoa que vai cadastrar o rosto'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _authorize(),
                ),
              ],
              _EnrollStep.term => [
                Text('Termo de consentimento: ${person!.name}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(faceTermText, key: Key('face-term')),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('face-term-agree'),
                  contentPadding: EdgeInsets.zero,
                  value: _agreed,
                  onChanged: (value) => setState(() => _agreed = value ?? false),
                  title: const Text('A pessoa leu o termo e concorda com o uso do rosto.'),
                ),
              ],
              _EnrollStep.read => [
                Text('Leitura do rosto: ${person!.name}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _CameraView(face: widget.face, message: _reader.message, failed: _reader.stage == FaceStage.failed),
              ],
              _EnrollStep.done => [
                Text('Rosto de ${person!.name} cadastrado.', key: const Key('face-enrolled')),
                const Text('Já vale neste terminal e chega aos outros PDVs da loja na próxima sincronização.'),
              ],
            },
          ),
        ),
      ),
      actions: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(_error!, key: const Key('face-enroll-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_step != _EnrollStep.done)
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        if (_step == _EnrollStep.authorize)
          FilledButton(key: const Key('enroll-authorize'), onPressed: _authorize, child: const Text('Continuar')),
        if (_step == _EnrollStep.term)
          FilledButton(
            key: const Key('face-term-continue'),
            onPressed: _agreed
                ? () {
                    _consentedAt = DateTime.now();
                    _read();
                  }
                : null,
            child: const Text('Ler o rosto'),
          ),
        if (_step == _EnrollStep.read && !_reading)
          FilledButton(key: const Key('face-enroll-retry'), onPressed: _read, child: const Text('Tentar de novo')),
        if (_step == _EnrollStep.done)
          FilledButton(key: const Key('face-enroll-close'), onPressed: () => Navigator.of(context).pop(), child: const Text('Fechar')),
      ],
    );
  }
}

/// Lê o rosto de quem vai liberar e devolve o código dela (com o vale de uso único da câmera já
/// dado). Nada se não reconhecer, se a pessoa não liberar pela câmera ou se a câmera falhar.
Future<String?> showFaceApproval(BuildContext context, PosController controller) {
  final face = controller.face;
  if (face == null) return Future.value();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _FaceApprovalDialog(controller: controller, face: face),
  );
}

class _FaceApprovalDialog extends StatefulWidget {
  const _FaceApprovalDialog({required this.controller, required this.face});

  final PosController controller;
  final FaceService face;

  @override
  State<_FaceApprovalDialog> createState() => _FaceApprovalDialogState();
}

class _FaceApprovalDialogState extends State<_FaceApprovalDialog> {
  FaceReader _reader = FaceReader();
  bool _closed = false;
  bool _reading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    _closed = true;
    widget.face.closeCamera();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    setState(() {
      _reader = FaceReader();
      _reading = true;
      _error = null;
    });
    if (!await widget.face.start()) {
      if (mounted) setState(() => _reading = false);
      if (mounted) setState(() => _error = 'A câmera não abriu. Use o código e o PIN.');
      return;
    }
    final engine = widget.face.engine!;
    final result = await readFace(
      camera: widget.face.camera!,
      engine: engine,
      reader: _reader,
      onUpdate: () {
        if (mounted) setState(() {});
      },
      cancelled: () => _closed,
    );
    if (_closed) return;
    _reading = false;
    if (result == null) {
      if (mounted) setState(() {});
      return;
    }
    final found = bestFaceMatch<LocalUser>(result, widget.controller.database.faceCandidates(engine.model));
    if (found == null) {
      setState(() => _error = 'Rosto não reconhecido. Tente de novo ou use o código e o PIN.');
      return;
    }
    try {
      widget.controller.auth.grantFace(found.match);
    } on PosException {
      setState(() => _error = '${found.match.name} libera com o PIN, não pela câmera.');
      return;
    }
    if (mounted) Navigator.of(context).pop('${found.match.code}');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('face-approval'),
      title: const Text('Liberar pela câmera'),
      content: SizedBox(
        width: 440,
        child: _CameraView(face: widget.face, message: _error ?? _reader.message, failed: _error != null || _reader.stage == FaceStage.failed),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        if (!_reading)
          FilledButton(key: const Key('face-approval-retry'), onPressed: _read, child: const Text('Tentar de novo')),
      ],
    );
  }
}

/// Botão "Liberar pela câmera" ao lado do código e do PIN de quem libera. Reconhecida a pessoa,
/// [onApproved] recebe o código dela; a tela confirma sem PIN e o vale da câmera vale no lugar.
class FaceApproveButton extends StatelessWidget {
  const FaceApproveButton({super.key, required this.controller, required this.onApproved});

  final PosController controller;
  final void Function(String code) onApproved;

  @override
  Widget build(BuildContext context) {
    if (controller.face == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('face-approve'),
        icon: const Icon(Icons.face),
        label: const Text('Liberar pela câmera'),
        onPressed: () async {
          final code = await showFaceApproval(context, controller);
          if (code != null) onApproved(code);
        },
      ),
    );
  }
}
