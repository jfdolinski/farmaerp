import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../ui/caps.dart';
import '../ui/keys_hint.dart';
import '../ui/pdv_window.dart';
import 'pos_controller.dart';

/// PBM da venda (F12): escolhe o programa ligado na loja, informa o CPF ou o cartão do beneficiário
/// e consulta. Os itens aceitos ficam com o preço do programa. Só com internet; sem ela, a venda
/// segue pelo preço normal.
Future<void> showPbmDialog(BuildContext context, PosController controller) {
  return showDialog<void>(context: context, builder: (_) => _PbmDialog(controller: controller));
}

class _PbmDialog extends StatefulWidget {
  const _PbmDialog({required this.controller});

  final PosController controller;

  @override
  State<_PbmDialog> createState() => _PbmDialogState();
}

class _PbmDialogState extends State<_PbmDialog> {
  final _document = TextEditingController();
  final _documentFocus = FocusNode();
  List<Map<String, dynamic>>? _programs;
  String? _programId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final programs = await widget.controller.loadPbmPrograms();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _programs = programs;
      _programId = programs != null && programs.isNotEmpty ? '${programs.first['id']}' : null;
      final notice = widget.controller.notice;
      if (programs == null && notice != null) _error = '${notice.message} ${notice.action}';
    });
    if (_programId != null) _documentFocus.requestFocus();
  }

  @override
  void dispose() {
    _document.dispose();
    _documentFocus.dispose();
    super.dispose();
  }

  Future<void> _consult() async {
    final programs = _programs ?? const [];
    final program = programs.where((item) => '${item['id']}' == _programId).firstOrNull;
    if (program == null) return;
    final ok = await widget.controller.applyPbm(
      programId: '${program['id']}',
      programName: '${program['name']}',
      beneficiary: _document.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      final notice = widget.controller.notice;
      _error = notice == null ? null : '${notice.message} ${notice.action}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final programs = _programs ?? const <Map<String, dynamic>>[];
    final busy = widget.controller.busy;
    return PdvWindow(
      size: PdvWindowSize.compact,
      title: 'PBM: programa de benefício',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const Text('Buscando os programas da loja...'),
          if (!_loading && _programs != null && programs.isEmpty)
            const Text('Nenhum programa de benefício está ligado nesta loja.', key: Key('pbm-none')),
          if (programs.isNotEmpty) ...[
            const Text('O preço do programa vale sozinho no item: os outros descontos saem dele.'),
            DropdownButtonFormField<String>(
              key: const Key('pbm-program'),
              initialValue: _programId,
              decoration: const InputDecoration(labelText: 'Programa'),
              items: [
                for (final program in programs)
                  DropdownMenuItem(value: '${program['id']}', child: Text('${program['name']}')),
              ],
              onChanged: (value) => setState(() => _programId = value),
            ),
            TextField(
              key: const Key('pbm-document'),
              controller: _document,
              focusNode: _documentFocus,
              decoration: const InputDecoration(labelText: 'CPF ou cartão do beneficiário'),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z.\-/ ]')), LengthLimitingTextInputFormatter(40)],
              onSubmitted: (_) => _consult(),
            ),
          ],
          if (_error != null) Text(_error!, key: const Key('pbm-error')),
        ],
      ),
      actions: [
        const KeysHint(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
        if (programs.isNotEmpty)
          FilledButton(
            key: const Key('pbm-consult'),
            onPressed: busy ? null : _consult,
            child: Text(busy ? 'Consultando...' : 'Consultar o programa'),
          ),
      ],
    );
  }
}
