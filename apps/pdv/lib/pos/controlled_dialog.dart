import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../face/face_widgets.dart';
import '../ui/caps.dart';
import 'controlled.dart';
import 'focus_kit.dart';
import '../local/local_database.dart' show LocalProfessional;
import 'cart.dart';
import 'money.dart';
import 'pos_controller.dart';

/// Ao finalizar, um controlado da venda sem receita: preencher, voltar aos itens ou tirar da venda.
class ControlledPanel extends StatelessWidget {
  const ControlledPanel({super.key, required this.controller, required this.pending, this.focusNode});

  final PosController controller;
  final PendingControlled pending;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('controlled-panel'),
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Antes de receber: ${pending.product.name} é controlado (lista ${pending.product.controlledClass}).',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(pending.suggestedType.requiresBuyer
                ? 'A venda precisa da ${pending.suggestedType.label.toLowerCase()}, dos dados do comprador e da liberação do farmacêutico.'
                : 'A venda precisa da ${pending.suggestedType.label.toLowerCase()}, da idade e do sexo do paciente e da liberação do farmacêutico.'),
            if (controller.controlledWithoutRelease.length > 1)
              Text('Controlados sem receita nesta venda: ${controller.controlledWithoutRelease.length}.'),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(key: const Key('controlled-back'), onPressed: controller.cancelControlled, child: const Text('Voltar aos itens')),
                TextButton(key: const Key('controlled-cancel'), onPressed: controller.dropControlled, child: const Text('Não vender')),
                FilledButton(
                  key: const Key('controlled-open'),
                  focusNode: focusNode,
                  onPressed: () => showControlledDialog(context, controller),
                  child: const Text('Preencher a receita'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showControlledDialog(BuildContext context, PosController controller) {
  final pending = controller.pendingControlled;
  if (pending == null) return Future.value();
  return showDialog<void>(context: context, builder: (_) => _ControlledDialog(controller: controller, pending: pending));
}

class _ControlledDialog extends StatefulWidget {
  const _ControlledDialog({required this.controller, required this.pending});

  final PosController controller;
  final PendingControlled pending;

  @override
  State<_ControlledDialog> createState() => _ControlledDialogState();
}

class _ControlledDialogState extends State<_ControlledDialog> {
  late final PrescriptionForm _form = PrescriptionForm(type: widget.pending.suggestedType);
  late final List<ControlledBatch> _batches = widget.controller.controlledBatches(widget.pending.product);
  late final _quantity = TextEditingController(text: '${(widget.pending.quantityMilli / 1000).ceil()}');
  final _fields = <String, TextEditingController>{};
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _reason = TextEditingController();
  String? _batchId;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _batchId = _batches.isEmpty ? null : _batches.first.id;
    _focusProblem();
  }

  @override
  void dispose() {
    for (final field in [..._fields.values, _quantity, _code, _pin, _reason, _prescriberSearch]) {
      field.dispose();
    }
    for (final node in [..._focuses.values, _reasonFocus, _codeFocus, _pinFocus]) {
      node.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String name) => _fields.putIfAbsent(name, TextEditingController.new);

  String? _reuseMessage;
  final _prescriberSearch = TextEditingController();
  List<LocalProfessional> _prescribers = const [];
  String? _prescriberMessage;

  /// Preenche o prescritor com um do cadastro.
  void _choosePrescriber(LocalProfessional professional) {
    setState(() {
      _form
        ..prescriberName = professional.name
        ..prescriberCouncil = professional.council
        ..prescriberNumber = professional.registration
        ..prescriberState = professional.state;
      _field('prescriberName').text = professional.name;
      _field('prescriberNumber').text = professional.registration;
      _field('prescriberState').text = professional.state;
      _prescribers = const [];
      _prescriberSearch.clear();
      _prescriberMessage = null;
      _formVersion += 1;
    });
    _focusProblem();
  }

  void _registerPrescriber() {
    _collect();
    final saved = widget.controller.registerPrescriber(_form);
    setState(() {
      _tried = true;
      _prescriberMessage = saved == null ? null : 'Prescritor cadastrado: ${saved.label}.';
    });
  }

  /// Muda quando a receita é trazida de outro item, para os campos de escolha mostrarem o valor novo.
  int _formVersion = 0;

  String _dateText(DateTime? value) => value == null
      ? ''
      : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

  /// Traz a receita de outro item da venda. Só com o mesmo tipo de receita.
  void _reuse(CartLine source) {
    final copy = reusePrescription(source.controlled!.form!, _form.type);
    setState(() {
      if (copy == null) {
        _reuseMessage = 'A receita de ${source.product.name} é ${source.controlled!.form!.type.label}; '
            'este item pede ${_form.type.label}.';
        return;
      }
      _form
        ..number = copy.number
        ..date = copy.date
        ..prescriberName = copy.prescriberName
        ..prescriberCouncil = copy.prescriberCouncil
        ..prescriberNumber = copy.prescriberNumber
        ..prescriberState = copy.prescriberState
        ..buyerName = copy.buyerName
        ..buyerDocumentType = copy.buyerDocumentType
        ..buyerDocument = copy.buyerDocument
        ..buyerIssuer = copy.buyerIssuer
        ..buyerState = copy.buyerState
        ..patientName = copy.patientName
        ..patientAge = copy.patientAge
        ..patientSex = copy.patientSex;
      final values = {
        'number': copy.number, 'date': _dateText(copy.date), 'prescriberName': copy.prescriberName,
        'prescriberNumber': copy.prescriberNumber, 'prescriberState': copy.prescriberState, 'buyerName': copy.buyerName,
        'buyerDocument': copy.buyerDocument, 'buyerIssuer': copy.buyerIssuer, 'buyerState': copy.buyerState,
        'patientName': copy.patientName, 'patientAge': copy.patientAge?.toString() ?? '',
      };
      values.forEach((name, value) => _field(name).text = value);
      _reuseMessage = _form.type.isNotification
          ? 'Dados trazidos de ${source.product.name}. A notificação vale para um só medicamento: informe o número e a data desta.'
          : 'Receita trazida de ${source.product.name}. Confira e escolha o lote.';
      _formVersion += 1;
    });
    _focusProblem();
  }

  int get _quantityMilli => (int.tryParse(_quantity.text) ?? 0) * 1000;

  /// Sem lote com saldo para a quantidade: só a liberação pendente.
  bool get _pendingOnly => !_batches.any((batch) => batch.availableMilli >= _quantityMilli);

  DateTime? _date(String text) {
    final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(text.trim());
    if (match == null) return null;
    final day = int.parse(match[1]!), month = int.parse(match[2]!), year = int.parse(match[3]!);
    final value = DateTime(year, month, day);
    return value.day == day && value.month == month ? value : null;
  }

  void _collect() {
    _form
      ..number = _field('number').text
      ..date = _date(_field('date').text)
      ..prescriberName = _field('prescriberName').text
      ..prescriberNumber = _field('prescriberNumber').text
      ..prescriberState = _field('prescriberState').text.trim().toUpperCase()
      ..buyerName = _field('buyerName').text
      ..buyerDocument = _field('buyerDocument').text
      ..buyerIssuer = _field('buyerIssuer').text
      ..buyerState = _field('buyerState').text.trim().toUpperCase()
      ..patientName = _field('patientName').text
      ..patientAge = int.tryParse(_field('patientAge').text);
  }

  Future<void> _release() async {
    _collect();
    setState(() => _tried = true);
    final ok = _pendingOnly
        ? await widget.controller.releaseControlledPending(
            reason: _reason.text, quantityMilli: _quantityMilli, code: _code.text, pin: _pin.text)
        : await widget.controller.releaseControlled(
            form: _form, batchId: _batchId ?? '', quantityMilli: _quantityMilli, code: _code.text, pin: _pin.text);
    _pin.clear();
    if (ok && mounted) Navigator.of(context).pop();
    if (mounted) {
      setState(() {});
      _focusProblem();
    }
  }

  static const _order = [
    'number', 'date', 'prescriberName', 'prescriberNumber', 'prescriberState', 'buyerName', 'buyerDocument',
    'buyerIssuer', 'buyerState', 'patientName', 'patientAge',
  ];
  final _focuses = <String, FocusNode>{};
  final _reasonFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  FocusNode _node(String name) => _focuses.putIfAbsent(name, FocusNode.new);

  /// Primeiro campo que falta (ou com problema); sem nada faltando, o código e o PIN.
  void _focusProblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pendingOnly) {
        (_reason.text.trim().isEmpty ? _reasonFocus : _code.text.trim().isEmpty ? _codeFocus : _pinFocus).requestFocus();
        return;
      }
      final errors = prescriptionErrors(_form, DateTime.now());
      final first = _order.where(errors.containsKey).firstOrNull;
      if (first != null) {
        _node(first).requestFocus();
      } else {
        (_code.text.trim().isEmpty ? _codeFocus : _pinFocus).requestFocus();
      }
    });
  }

  Widget _text(String name, String label, {Map<String, String> errors = const {}, double width = 220, TextInputType? keyboard,
      List<TextInputFormatter>? formatters, String? hint}) {
    return SizedBox(
      width: width,
      child: TextField(
        key: Key('rx-$name'),
        controller: _field(name),
        focusNode: _node(name),
        keyboardType: keyboard,
        inputFormatters: formatters,
        decoration: InputDecoration(labelText: label, hintText: hint, errorText: _tried ? errors[name] : null),
        onChanged: (_) => setState(_collect),
      ),
    );
  }

  static final _state = [
    FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
    LengthLimitingTextInputFormatter(2),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final pending = widget.pending;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pendingOnly = _pendingOnly;
        final errors = pendingOnly ? const <String, String>{} : prescriptionErrors(_form, DateTime.now());
        final notice = controller.notice;
        final sources = controller.prescriptionSources(pending);
        return AlertDialog(
          key: const Key('controlled-dialog'),
          title: Text('Controlado · ${pending.product.name}'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (notice != null)
                    Container(
                      key: const Key('controlled-notice'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(bottom: 8),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Text('${notice.message} ${notice.action}'),
                    ),
                  if (!pendingOnly && sources.isNotEmpty) ...[
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final (index, source) in sources.indexed)
                        OutlinedButton(
                          key: Key('rx-reuse-$index'),
                          onPressed: () => _reuse(source),
                          child: Text('Usar a receita de ${source.product.name}'),
                        ),
                    ]),
                    if (_reuseMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_reuseMessage!, key: const Key('rx-reuse-message')),
                      ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      SizedBox(
                        width: 120,
                        child: NumberField(
                          key: const Key('rx-quantity'),
                          controller: _quantity,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                          decoration: const InputDecoration(labelText: 'Quantidade'),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      if (_batches.isNotEmpty && !pendingOnly)
                        SizedBox(
                          width: 420,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            key: const Key('rx-batch'),
                            initialValue: _batchId,
                            decoration: const InputDecoration(labelText: 'Lote (o que vence primeiro vem antes)'),
                            items: [
                              for (final batch in _batches)
                                DropdownMenuItem(
                                  value: batch.id,
                                  child: Text('${batch.number} · vence ${batch.expiresOn.split('-').reversed.join('/')} · '
                                      'saldo ${formatMilli(batch.availableMilli)}'),
                                ),
                            ],
                            onChanged: (value) => setState(() => _batchId = value),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (pendingOnly) ...[
                    Text(
                      _batches.isEmpty
                          ? 'Não há saldo em lote deste controlado na cópia do terminal.'
                          : 'Nenhum lote tem saldo para essa quantidade.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      'O farmacêutico pode liberar a venda com o estoque negativo. Ela fica pendente e os dados da receita '
                      'e do comprador são completados depois, na retaguarda, para o SNGPC. Guarde a receita.',
                    ),
                    TextField(
                      key: const Key('rx-pending-reason'),
                      controller: _reason,
                      focusNode: _reasonFocus,
                      maxLength: 500,
                      decoration: InputDecoration(
                        labelText: 'Motivo (por exemplo, nota de entrada ainda não lançada)',
                        errorText: _tried && _reason.text.trim().isEmpty ? 'Informe o motivo' : null,
                      ),
                    ),
                  ] else ...[
                    Text('Receita', style: Theme.of(context).textTheme.titleSmall),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      SizedBox(
                        width: 280,
                        child: DropdownButtonFormField<PrescriptionType>(
                          isExpanded: true,
                          key: const Key('rx-type'),
                          initialValue: _form.type,
                          decoration: InputDecoration(
                            labelText: 'Tipo de receita',
                            helperText: _form.type == pending.suggestedType ? null : 'A lista pede ${pending.suggestedType.label}',
                          ),
                          items: [for (final type in PrescriptionType.values) DropdownMenuItem(value: type, child: Text(type.label))],
                          onChanged: (value) => setState(() => _form.type = value ?? _form.type),
                        ),
                      ),
                      _text('number', _form.type.isNotification ? 'Número da notificação' : 'Número da receita', errors: errors),
                      _text('date', 'Data da receita', errors: errors, width: 160, hint: 'dd/mm/aaaa', keyboard: TextInputType.datetime,
                          formatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d/]')), LengthLimitingTextInputFormatter(10)]),
                    ]),
                    const SizedBox(height: 12),
                    Text('Prescritor', style: Theme.of(context).textTheme.titleSmall),
                    SizedBox(
                      width: 420,
                      child: TextField(
                        key: const Key('rx-prescriber-search'),
                        controller: _prescriberSearch,
                        decoration: const InputDecoration(labelText: 'Buscar no cadastro (nome ou número no conselho)'),
                        onChanged: (value) => setState(() => _prescribers = controller.searchPrescribers(value)),
                      ),
                    ),
                    if (_prescribers.isNotEmpty)
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final (index, professional) in _prescribers.indexed)
                          ActionChip(
                            key: Key('rx-prescriber-$index'),
                            label: Text(professional.label),
                            onPressed: () => _choosePrescriber(professional),
                          ),
                      ])
                    else if (_prescriberSearch.text.trim().length >= 2)
                      const Text('Nenhum prescritor encontrado. Preencha abaixo e cadastre.'),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      _text('prescriberName', 'Nome', errors: errors, width: 300),
                      SizedBox(
                        width: 110,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: Key('rx-council-$_formVersion'),
                          initialValue: _form.prescriberCouncil,
                          decoration: const InputDecoration(labelText: 'Conselho'),
                          items: [for (final council in prescriberCouncils) DropdownMenuItem(value: council, child: Text(council))],
                          onChanged: (value) => setState(() => _form.prescriberCouncil = value ?? 'CRM'),
                        ),
                      ),
                      _text('prescriberNumber', 'Número', errors: errors, width: 140),
                      _text('prescriberState', 'UF', errors: errors, width: 70, formatters: _state),
                      if (!controller.prescriberRegistered(_form))
                        OutlinedButton(
                          key: const Key('rx-prescriber-save'),
                          onPressed: _registerPrescriber,
                          child: const Text('Cadastrar prescritor'),
                        ),
                    ]),
                    if (_prescriberMessage != null) Text(_prescriberMessage!, key: const Key('rx-prescriber-message')),
                    const SizedBox(height: 12),
                    Text(_form.type.requiresBuyer ? 'Comprador' : 'Comprador (opcional no antimicrobiano)',
                        style: Theme.of(context).textTheme.titleSmall),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      _text('buyerName', 'Nome', errors: errors, width: 300),
                      SizedBox(
                        width: 140,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: Key('rx-document-type-$_formVersion'),
                          initialValue: _form.buyerDocumentType,
                          decoration: const InputDecoration(labelText: 'Documento'),
                          items: [
                            for (final entry in buyerDocumentTypes.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                          ],
                          onChanged: (value) => setState(() => _form.buyerDocumentType = value ?? 'rg'),
                        ),
                      ),
                      _text('buyerDocument', 'Número do documento', errors: errors, width: 180),
                      _text('buyerIssuer', 'Órgão emissor', errors: errors, width: 120),
                      _text('buyerState', 'UF', errors: errors, width: 70, formatters: _state),
                    ]),
                    const SizedBox(height: 12),
                    Text(
                      _form.type == PrescriptionType.antimicrobial ? 'Paciente (idade e sexo obrigatórios)' : 'Paciente (opcional)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      _text('patientName', 'Nome', errors: errors, width: 300),
                      _text('patientAge', 'Idade', errors: errors, width: 90, keyboard: TextInputType.number,
                          formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)]),
                      SizedBox(
                        width: 140,
                        child: DropdownButtonFormField<String?>(
                          isExpanded: true,
                          key: Key('rx-patient-sex-$_formVersion'),
                          initialValue: _form.patientSex,
                          decoration: InputDecoration(labelText: 'Sexo', errorText: _tried ? errors['patientSex'] : null),
                          items: const [
                            DropdownMenuItem(value: null, child: Text('—')),
                            DropdownMenuItem(value: 'F', child: Text('Feminino')),
                            DropdownMenuItem(value: 'M', child: Text('Masculino')),
                          ],
                          onChanged: (value) => setState(() => _form.patientSex = value),
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 12),
                  Text('Liberação do farmacêutico', style: Theme.of(context).textTheme.titleSmall),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    SizedBox(
                      width: 160,
                      child: TextField(
                        key: const Key('rx-code'),
                        controller: _code,
                        focusNode: _codeFocus,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: 'Código'),
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        key: const Key('rx-pin'),
                        controller: _pin,
                        focusNode: _pinFocus,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        decoration: const InputDecoration(labelText: 'PIN'),
                        onSubmitted: (_) => _release(),
                      ),
                    ),
                  ]),
                  FaceApproveButton(
                    controller: widget.controller,
                    onApproved: (code) {
                      _code.text = code;
                      _pin.clear();
                      _release();
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Voltar')),
            FilledButton(
              key: const Key('rx-release'),
              onPressed: controller.busy ? null : _release,
              child: Text(pendingOnly ? 'Liberar pendente' : 'Liberar a venda'),
            ),
          ],
        );
      },
    );
  }
}
