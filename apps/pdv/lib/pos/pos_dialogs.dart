import 'dart:async';

import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../core/document.dart';
import '../customers/customer_service.dart';
import '../core/error_display.dart';
import '../face/face_widgets.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';
import '../ui/caps.dart';
import '../ui/pdv_window.dart';
import '../ui/keys_hint.dart';
import '../ui/date_field.dart';
import 'cart.dart';
import 'customer_statement.dart';
import 'discount.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';

/// Desconto no item, em R$ ou em %. Acima do limite, pede o supervisor na mesma janela.
Future<void> showDiscountDialog(BuildContext context, PosController controller, CartLine line) {
  return showDialog<void>(context: context, builder: (_) => _DiscountDialog(controller: controller, line: line));
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.controller, required this.line});

  final PosController controller;
  final CartLine line;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _value = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _reason = TextEditingController();
  final _valueFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  bool _percent = true;

  void _focus(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) node.requestFocus();
  });
  bool _needsRelease = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _code.dispose();
    _pin.dispose();
    _reason.dispose();
    _valueFocus.dispose();
    _codeFocus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  int? get _cents {
    final gross = widget.line.grossCents;
    if (_percent) {
      final bp = parseCents(_value.text); // "8,5" → 850 centésimos de ponto
      return bp == null ? null : (gross * bp / 10000).round();
    }
    return parseCents(_value.text);
  }

  Future<void> _apply() async {
    final cents = _cents;
    if (cents == null) {
      setState(() => _error = _percent ? 'Digite o percentual, por exemplo 5 ou 7,5.' : 'Digite o valor, por exemplo 1,50.');
      _focus(_valueFocus);
      return;
    }
    if (!_needsRelease) {
      final need = widget.controller.applyDiscount(widget.line, cents);
      if (widget.controller.notice != null) {
        setState(() => _error = widget.controller.notice!.message);
        _focus(_valueFocus);
        return;
      }
      if (need == DiscountNeed.release) {
        setState(() {
          _needsRelease = true;
          _error = null;
        });
        _focus(_codeFocus);
        return;
      }
      if (mounted) Navigator.pop(context);
      return;
    }
    final ok = await widget.controller.releaseDiscount(widget.line, cents, _code.text, _pin.text, _reason.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _error = widget.controller.notice?.message;
        _pin.clear();
      });
      _focus(_code.text.trim().isEmpty ? _codeFocus : _pinFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final notice = _needsRelease ? ErrorDisplay.fromCode('FA978') : null;
    return PdvWindow(
      title: 'Desconto no item',
      subtitle: line.product.name,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        // Folga entre os campos: o rótulo de cima não encosta no texto.
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Valor do item: ${formatCents(line.grossCents)}'),
          if (line.product.maxDiscountBp != null)
            Text('Máximo do produto: ${formatCents(line.product.maxDiscountBp!).replaceFirst('R\$ ', '')}%'),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: true, label: Text('%')), ButtonSegment(value: false, label: Text('R\$'))],
            selected: {_percent},
            onSelectionChanged: _needsRelease ? null : (value) => setState(() => _percent = value.first),
          ),
          NumberField(
            key: const Key('discount-value'),
            controller: _value,
            focusNode: _valueFocus,
            autofocus: true,
            decimal: true,
            enabled: !_needsRelease,
            decoration: InputDecoration(labelText: _percent ? 'Desconto (%)' : 'Desconto (R\$)'),
            onSubmitted: (_) => _apply(),
          ),
          if (notice != null) ...[
            const SizedBox(height: 12),
            Text(notice.message, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(notice.action),
            TextField(
              key: const Key('supervisor-code'),
              controller: _code,
              focusNode: _codeFocus,
              onSubmitted: (_) => _pinFocus.requestFocus(),
              decoration: const InputDecoration(labelText: 'Código do supervisor'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            TextField(
              key: const Key('supervisor-pin'),
              controller: _pin,
              focusNode: _pinFocus,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN do supervisor'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            ),
            FaceApproveButton(
              controller: widget.controller,
              onApproved: (code) {
                _code.text = code;
                _pin.clear();
                _apply();
              },
            ),
            TextField(key: const Key('release-reason'), controller: _reason, decoration: const InputDecoration(labelText: 'Motivo')),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const Key('discount-error'))),
        ],
      ),
      actions: [
        const KeysHint(),
        if (line.manualDiscountCents > 0)
          TextButton(
            onPressed: () {
              widget.controller.applyDiscount(line, 0);
              Navigator.pop(context);
            },
            child: const Text('Tirar o desconto'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          key: const Key('discount-apply'),
          onPressed: widget.controller.busy ? null : _apply,
          child: Text(_needsRelease ? 'Liberar' : 'Aplicar'),
        ),
      ],
    );
  }
}

/// Venda sem estoque com o PDV sem internet há bastante tempo: o gerente autoriza aqui.
class ZeroStockPanel extends StatefulWidget {
  const ZeroStockPanel({super.key, required this.controller, required this.pending, this.focusNode});

  final PosController controller;
  final PendingZeroStock pending;
  final FocusNode? focusNode;

  @override
  State<ZeroStockPanel> createState() => _ZeroStockPanelState();
}

class _ZeroStockPanelState extends State<ZeroStockPanel> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    await widget.controller.approveZeroStock(_code.text, _pin.text);
    _pin.clear();
    if (mounted && widget.controller.pendingZeroStock != null) {
      (_code.text.trim().isEmpty ? widget.focusNode : _pinFocus)?.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final offline = pending.minutesOffline;
    final stock = pending.product.stockMilli;
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('zero-stock-panel'),
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${pending.product.name}: o estoque fica negativo (saldo ${stock < 0 ? '-' : ''}${formatMilli(stock.abs())}).',
              key: const Key('zero-stock-title'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '${offline == null ? '' : 'O PDV está sem sincronizar há ${offline ~/ 60 > 0 ? '${offline ~/ 60} h ' : ''}${offline % 60} min. '}'
              'Para vender assim, quem tem "Vender com estoque negativo" digita o código e o PIN. Fica registrado para conferência.',
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('zero-stock-code'),
                    controller: _code,
                    focusNode: widget.focusNode,
                    onSubmitted: (_) => _pinFocus.requestFocus(),
                    decoration: const InputDecoration(labelText: 'Código de quem libera'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('zero-stock-pin'),
                    controller: _pin,
                    focusNode: _pinFocus,
                    onSubmitted: (_) => _approve(),
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'PIN'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  ),
                ),
              ],
            ),
            FaceApproveButton(
              controller: widget.controller,
              onApproved: (code) {
                _code.text = code;
                _pin.clear();
                _approve();
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: widget.controller.cancelZeroStock, child: const Text('Não vender')),
                FilledButton(
                  key: const Key('zero-stock-approve'),
                  onPressed: widget.controller.busy ? null : _approve,
                  child: const Text('Liberar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Estoque do produto nas filiais (com internet).
Future<void> showNetworkStock(BuildContext context, PosController controller, SaleProduct product) async {
  final rows = await controller.stockElsewhere(product);
  if (rows == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => PdvWindow(
      key: const Key('network-stock'),
      title: 'Estoque nas filiais',
      subtitle: product.name,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in rows)
            ListTile(
              key: Key('network-${row['branch_id']}'),
              title: Text('${row['branch_name']}${row['own'] == true ? ' (esta filial)' : ''}'),
              subtitle: Text([row['city'], row['phone']].whereType<String>().join(' · ')),
              trailing: Text(formatMilli(((row['quantity'] as num) * 1000).round().clamp(0, 1 << 40))),
            ),
        ],
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
    ),
  );
}

/// Identificação do cliente: busca com internet (ou entre os guardados) e escolha.
/// Histórico do cliente da venda: ticket médio, compras dos últimos 30 dias e recorrentes.
/// Extrato do cliente da venda, na tela toda.
Future<void> showCustomerHistoryDialog(BuildContext context, PosController controller) {
  final customer = controller.cart.customer;
  final service = controller.customers;
  if (customer == null || service == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => CustomerStatement(customer: customer, history: service.history(customer.id)),
  );
}

Future<void> showCustomerDialog(BuildContext context, PosController controller) {
  return showDialog<void>(context: context, builder: (_) => _CustomerDialog(controller: controller));
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({required this.controller});

  final PosController controller;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  final _query = TextEditingController();
  List<CustomerSummary> _results = const [];
  bool? _online;
  String? _error;
  bool _searching = false;
  int _highlight = -1;
  int _sequence = 0;
  Timer? _typing;

  // Cadastro na tela de vendas (com internet).
  bool _creating = false;
  final _newName = TextEditingController();
  final _newDocument = TextEditingController();
  final _newPhone = TextEditingController();
  final _newBirth = TextEditingController();
  bool _cashbackConsent = false;
  bool _marketingConsent = false;
  bool _tried = false;
  String? _createError;
  bool _duplicate = false;

  // Pessoa jurídica: o que a NF-e exige do destinatário. A consulta do CNPJ preenche o que achar.
  bool _company = false;
  final _cnpj = TextEditingController();
  final _legalName = TextEditingController();
  final _tradeName = TextEditingController();
  final _stateRegistration = TextEditingController();
  final _email = TextEditingController();
  final _postalCode = TextEditingController();
  final _street = TextEditingController();
  final _streetNumber = TextEditingController();
  final _complement = TextEditingController();
  final _district = TextEditingController();
  final _city = TextEditingController();
  final _cityCode = TextEditingController();
  final _uf = TextEditingController();

  /// 1 contribuinte, 2 isento, 9 não contribuinte; null segue a inscrição.
  int? _ieIndicator;
  bool _lookingUp = false;
  String? _lookupMessage;

  List<TextEditingController> get _companyFields => [
    _cnpj, _legalName, _tradeName, _stateRegistration, _email, _postalCode, _street, _streetNumber, _complement, _district, _city,
    _cityCode, _uf,
  ];

  @override
  void dispose() {
    _typing?.cancel();
    for (final field in [_query, _newName, _newDocument, _newPhone, _newBirth, ..._companyFields]) {
      field.dispose();
    }
    super.dispose();
  }

  /// Supervisor que liberou o cadastro (quem está no terminal não tem "Cadastrar cliente no PDV").
  String? _authorizedBy;

  /// Abre o cadastro aproveitando o que foi digitado na busca (CPF ou nome). Sem a permissão,
  /// pede antes a liberação de um supervisor.
  Future<void> _startCreating() async {
    if (!widget.controller.can('pdv.customer_create') && _authorizedBy == null) {
      final released = await showRegistrationRelease(context, widget.controller, permission: 'pdv.customer_create', what: 'cliente');
      if (!mounted || released == null) return;
      _authorizedBy = released;
    }
    final typed = _query.text.trim();
    final digits = typed.replaceAll(RegExp(r'[^0-9]'), '');
    setState(() {
      _creating = true;
      _createError = null;
      _duplicate = false;
      final onlyDocument = digits.length >= typed.replaceAll(RegExp(r'[\s.\-/]'), '').length;
      if (digits.length == 11 && onlyDocument) {
        _newDocument.text = digits;
      } else if (digits.length == 14 && onlyDocument) {
        // CNPJ digitado na busca: o cadastro já abre como pessoa jurídica.
        _company = true;
        _cnpj.text = digits;
      } else if (isValidCnpj(typed) && RegExp(r'^[0-9A-Za-z.\-/\s]+$').hasMatch(typed)) {
        // CNPJ alfanumérico digitado na busca: também abre como pessoa jurídica.
        _company = true;
        _cnpj.text = typed.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
      } else if (typed.isNotEmpty && digits.isEmpty) {
        _newName.text = typed;
      }
    });
  }

  DateTime? get _birth {
    final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(_newBirth.text.trim());
    if (match == null) return null;
    final day = int.parse(match[1]!), month = int.parse(match[2]!), year = int.parse(match[3]!);
    final value = DateTime(year, month, day);
    return value.day == day && value.month == month && year >= 1900 && !value.isAfter(DateTime.now()) ? value : null;
  }

  /// Campos com problema, conferidos aqui antes de ir à central.
  Map<String, String> get _newErrors => {
    if (_newName.text.trim().length < 3) 'name': 'Informe o nome completo',
    if (!isValidCpf(_newDocument.text)) 'document': 'CPF inválido',
    if (_newPhone.text.trim().isNotEmpty && !RegExp(r'^\d{10,11}$').hasMatch(_newPhone.text.replaceAll(RegExp(r'[^0-9]'), '')))
      'phone': 'Telefone com DDD (10 ou 11 dígitos)',
    if (_newBirth.text.trim().isNotEmpty && _birth == null) 'birth': 'Data inválida (dd/mm/aaaa)',
  };

  String _digits(TextEditingController field) => field.text.replaceAll(RegExp(r'[^0-9]'), '');

  /// Campos da pessoa jurídica com problema. O endereço é todo obrigatório (vai na NF-e).
  Map<String, String> get _companyErrors {
    final registration = _stateRegistration.text.trim().toUpperCase();
    final numbered = RegExp(r'^\d+$').hasMatch(_digits(_stateRegistration)) && registration != 'ISENTO';
    return {
      if (!isValidCnpj(_cnpj.text)) 'cnpj': 'CNPJ inválido',
      if (_legalName.text.trim().length < 3) 'legalName': 'Informe a razão social',
      if (registration.isNotEmpty && registration != 'ISENTO' && _digits(_stateRegistration).isEmpty) 'ie': 'Números ou ISENTO',
      if (_ieIndicator == 1 && !numbered) 'ie': 'Contribuinte precisa da inscrição com número',
      if (_ieIndicator == 2 && numbered) 'ie': 'Isento não tem inscrição com número',
      if (_email.text.trim().isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) 'email': 'E-mail inválido',
      if (_newPhone.text.trim().isNotEmpty && !RegExp(r'^\d{10,11}$').hasMatch(_digits(_newPhone))) 'phone': 'Telefone com DDD (10 ou 11 dígitos)',
      if (_digits(_postalCode).length != 8) 'postalCode': 'CEP com 8 dígitos',
      if (_street.text.trim().isEmpty) 'street': 'Informe a rua',
      if (_streetNumber.text.trim().isEmpty) 'streetNumber': 'Informe o número (ou S/N)',
      if (_district.text.trim().isEmpty) 'district': 'Informe o bairro',
      if (_city.text.trim().isEmpty) 'city': 'Informe o município',
      if (_digits(_cityCode).length != 7) 'cityCode': 'Código IBGE com 7 dígitos',
      if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(_uf.text.trim())) 'uf': 'UF com 2 letras',
    };
  }

  CompanyCustomer get _companyData => CompanyCustomer(
    cnpj: _cnpj.text,
    legalName: _legalName.text,
    tradeName: _tradeName.text,
    stateRegistration: _stateRegistration.text.trim().toUpperCase() == 'ISENTO' ? 'ISENTO' : _digits(_stateRegistration),
    ieIndicator: _ieIndicator,
    email: _email.text,
    phone: _newPhone.text,
    postalCode: _postalCode.text,
    street: _street.text,
    streetNumber: _streetNumber.text,
    complement: _complement.text,
    district: _district.text,
    city: _city.text,
    cityCode: _cityCode.text,
    state: _uf.text,
  );

  /// Preenche o cadastro pelo CNPJ (com internet). O que vier substitui o que está nos campos.
  Future<void> _lookup() async {
    if (!isValidCnpj(_cnpj.text)) {
      setState(() {
        _tried = true;
        _lookupMessage = null;
      });
      return;
    }
    setState(() {
      _lookingUp = true;
      _lookupMessage = null;
    });
    final result = await widget.controller.lookupCnpj(_cnpj.text, authorizedBy: _authorizedBy);
    if (!mounted) return;
    final data = result.data;
    setState(() {
      _lookingUp = false;
      if (data == null) {
        final display = ErrorDisplay.fromCode(result.code ?? 'FA000');
        _lookupMessage = '${display.message} ${display.action} Preencha os campos à mão.';
        return;
      }
      void put(TextEditingController field, String? value) => field.text = value ?? '';
      put(_legalName, data.legalName);
      put(_tradeName, data.tradeName);
      put(_email, data.email);
      put(_newPhone, data.phone);
      put(_postalCode, data.postalCode);
      put(_street, data.street);
      put(_streetNumber, data.streetNumber);
      put(_complement, data.complement);
      put(_district, data.district);
      put(_city, data.city);
      put(_cityCode, data.cityCode);
      put(_uf, data.state);
      _lookupMessage = 'Dados da Receita preenchidos. Confira e informe a inscrição estadual.';
    });
  }

  Future<void> _create() async {
    setState(() {
      _tried = true;
      _createError = null;
      _duplicate = false;
    });
    if (_company ? _companyErrors.isNotEmpty : _newErrors.isNotEmpty) return;
    final code = await widget.controller.createCustomer(
      name: _newName.text,
      document: _newDocument.text.replaceAll(RegExp(r'[^0-9]'), ''),
      phone: _newPhone.text.replaceAll(RegExp(r'[^0-9]'), ''),
      birthDate: _company ? null : _birth,
      company: _company ? _companyData : null,
      cashbackConsent: _cashbackConsent,
      marketingConsent: _marketingConsent,
      authorizedBy: _authorizedBy,
    );
    if (!mounted) return;
    if (code == null) {
      Navigator.pop(context);
      return;
    }
    final display = ErrorDisplay.fromCode(code);
    setState(() {
      _createError = '${display.message} ${display.action}';
      _duplicate = code == 'FA901';
    });
  }

  /// CPF ou CNPJ já cadastrado: volta para a busca pelo documento.
  void _searchDuplicate() {
    setState(() {
      _creating = false;
      _query.text = (_company ? _cnpj : _newDocument).text.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    });
    _search();
  }

  /// Campos da pessoa jurídica: CNPJ com a busca dos dados, inscrição e indicador, contato e endereço.
  List<Widget> _companyForm(
    Map<String, String> errors,
    Widget Function(String key, String label, TextEditingController controller, {TextInputType? keyboard, String? hint}) field,
  ) {
    Widget pair(Widget first, Widget second, {int flex = 2}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [Expanded(flex: flex, child: first), Expanded(child: second)],
    );
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Expanded(child: field('cnpj', 'CNPJ', _cnpj, keyboard: TextInputType.number)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              key: const Key('customer-new-lookup'),
              onPressed: _lookingUp ? null : _lookup,
              child: Text(_lookingUp ? 'Buscando...' : 'Buscar dados do CNPJ'),
            ),
          ),
        ],
      ),
      if (_lookupMessage != null) Text(_lookupMessage!, key: const Key('customer-new-lookup-message')),
      field('legalName', 'Razão social', _legalName),
      field('tradeName', 'Nome fantasia (opcional)', _tradeName),
      pair(
        field('ie', 'Inscrição estadual', _stateRegistration, hint: 'Números ou ISENTO'),
        DropdownButtonFormField<int?>(
          key: const Key('customer-new-ie-indicator'),
          initialValue: _ieIndicator,
          decoration: const InputDecoration(labelText: 'Contribuinte do ICMS'),
          items: const [
            DropdownMenuItem(value: null, child: Text('Pela inscrição')),
            DropdownMenuItem(value: 1, child: Text('Contribuinte')),
            DropdownMenuItem(value: 2, child: Text('Isento')),
            DropdownMenuItem(value: 9, child: Text('Não contribuinte')),
          ],
          onChanged: (value) => setState(() => _ieIndicator = value),
        ),
        flex: 1,
      ),
      pair(
        field('email', 'E-mail para a NF-e (opcional)', _email, keyboard: TextInputType.emailAddress),
        field('phone', 'Telefone com DDD (opcional)', _newPhone, keyboard: TextInputType.phone),
      ),
      pair(field('street', 'Rua', _street), field('streetNumber', 'Número', _streetNumber), flex: 3),
      pair(field('complement', 'Complemento (opcional)', _complement), field('postalCode', 'CEP', _postalCode, keyboard: TextInputType.number)),
      pair(field('district', 'Bairro', _district), field('uf', 'UF', _uf)),
      pair(field('city', 'Município', _city), field('cityCode', 'Código IBGE do município', _cityCode, keyboard: TextInputType.number)),
    ];
  }

  Widget _createForm() {
    final errors = !_tried ? const <String, String>{} : _company ? _companyErrors : _newErrors;
    Widget field(String key, String label, TextEditingController controller, {TextInputType? keyboard, String? hint}) => TextField(
      key: Key('customer-new-$key'),
      controller: controller,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, hintText: hint, errorText: errors[key]),
      onChanged: (_) => _tried ? setState(() {}) : null,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      // Folga entre os campos: o rótulo de cima não encosta no texto.
      spacing: 10,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          key: const Key('customer-new-kind'),
          segments: const [
            ButtonSegment(value: false, label: Text('Pessoa física')),
            ButtonSegment(value: true, label: Text('Pessoa jurídica')),
          ],
          selected: {_company},
          onSelectionChanged: (value) => setState(() {
            _company = value.first;
            _createError = null;
            _duplicate = false;
          }),
        ),
        if (_company) ..._companyForm(errors, field) else ...[
        field('name', 'Nome completo', _newName),
        field('document', 'CPF', _newDocument, keyboard: TextInputType.number),
        field('phone', 'Telefone com DDD (opcional)', _newPhone, keyboard: TextInputType.phone),
        DateField(
          key: const Key('customer-new-birth'),
          controller: _newBirth,
          label: 'Nascimento (opcional)',
          errorText: errors['birth'],
          lastDate: DateTime.now(),
          onChanged: (_) => _tried ? setState(() {}) : null,
        ),
        ],
        CheckboxListTile(
          key: const Key('customer-new-cashback'),
          contentPadding: EdgeInsets.zero,
          value: _cashbackConsent,
          onChanged: (value) => setState(() => _cashbackConsent = value ?? false),
          title: const Text('Aceita participar do cashback'),
        ),
        CheckboxListTile(
          key: const Key('customer-new-marketing'),
          contentPadding: EdgeInsets.zero,
          value: _marketingConsent,
          onChanged: (value) => setState(() => _marketingConsent = value ?? false),
          title: const Text('Aceita receber ofertas'),
        ),
        const Text('Os dados ficam protegidos (LGPD) e só são usados para as compras e o que o cliente aceitou acima.'),
        if (_createError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_createError!, key: const Key('customer-new-error')),
          ),
        if (_duplicate)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('customer-new-find'),
              onPressed: _searchDuplicate,
              child: const Text('Buscar o cliente por este CPF'),
            ),
          ),
      ],
    );
  }

  /// Sugestões enquanto digita: a partir de 3 letras, com uma pausa curta entre as teclas.
  void _onTyping(String text) {
    _typing?.cancel();
    if (text.trim().length < 3) return;
    _typing = Timer(const Duration(milliseconds: 350), () {
      if (mounted && _query.text == text) _search();
    });
  }

  Future<void> _search() async {
    final service = widget.controller.customers;
    if (service == null) return;
    final sequence = ++_sequence;
    final text = _query.text;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await service.search(text);
      // Resposta velha (o operador continuou digitando): ignora.
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _results = result.customers;
        _online = result.online;
        _highlight = result.customers.isEmpty ? -1 : 0;
        if (result.customers.isEmpty) _error = 'Nenhum cliente encontrado.';
      });
    } on ApiException catch (error) {
      if (mounted && sequence == _sequence) setState(() => _error = ErrorDisplay.fromCode(error.code).message);
    } finally {
      if (mounted && sequence == _sequence) setState(() => _searching = false);
    }
  }

  Future<void> _choose(CustomerSummary customer) async {
    await widget.controller.selectCustomer(customer.id);
    if (mounted) Navigator.pop(context);
  }

  /// Enter: escolhe a sugestão marcada; sem sugestão, busca.
  void _submit() {
    _typing?.cancel();
    if (_highlight >= 0 && _highlight < _results.length) {
      _choose(_results[_highlight]);
    } else {
      _search();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PdvWindow(
      title: _creating ? 'Cadastrar cliente' : 'Identificar o cliente',
      content: _creating ? SingleChildScrollView(child: _createForm()) : Column(
        mainAxisSize: MainAxisSize.min,
        // Folga entre os campos: o rótulo de cima não encosta no texto.
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SuggestionKeys(
            onMove: (step) {
              if (_results.isEmpty) return;
              setState(() => _highlight = (_highlight + step).clamp(0, _results.length - 1));
            },
            onClose: () => Navigator.pop(context),
            child: TextField(
              key: const Key('customer-query'),
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nome, código ou CPF/CNPJ', helperText: 'As sugestões aparecem a partir de 3 letras.'),
              onChanged: (text) {
                _onTyping(text);
                setState(() {});
              },
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (_online == false)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Sem internet: a lista mostra só os clientes já usados neste terminal.', key: Key('customer-offline')),
            ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
          if (_searching) const LinearProgressIndicator(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (index, customer) in _results.indexed)
                  ListTile(
                    key: Key('customer-${customer.code}'),
                    selected: index == _highlight,
                    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                    title: Text(customer.name),
                    subtitle: Text([
                      'Código ${customer.code}',
                      ?customer.documentMasked,
                      if (customer.city != null) '${customer.city}/${customer.state ?? ''}',
                    ].join(' · ')),
                    onTap: () => _choose(customer),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        const KeysHint(),
        if (_creating) ...[
          TextButton(key: const Key('customer-new-back'), onPressed: () => setState(() => _creating = false), child: const Text('Voltar à busca')),
          FilledButton(
            key: const Key('customer-new-save'),
            onPressed: widget.controller.busy ? null : _create,
            child: const Text('Cadastrar e usar na venda'),
          ),
        ] else ...[
          TextButton(key: const Key('customer-new'), onPressed: _startCreating, child: const Text('Cadastrar cliente')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
          FilledButton(key: const Key('customer-search'), onPressed: _searching ? null : _search, child: const Text('Buscar')),
        ],
      ],
    );
  }
}

/// Cancelar a última venda: motivo (vai para a Sefaz) e a liberação do supervisor. A central
/// cancela a NFC-e e desfaz a venda.
Future<void> showCancelSaleDialog(BuildContext context, PosController controller) {
  return showDialog<void>(context: context, builder: (_) => _CancelSaleDialog(controller: controller));
}

class _CancelSaleDialog extends StatefulWidget {
  const _CancelSaleDialog({required this.controller});

  final PosController controller;

  @override
  State<_CancelSaleDialog> createState() => _CancelSaleDialogState();
}

class _CancelSaleDialogState extends State<_CancelSaleDialog> {
  final _reason = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    _code.dispose();
    _pin.dispose();
    _codeFocus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_reason.text.trim().length < 15) {
      setState(() => _error = 'Escreva o motivo com pelo menos 15 letras.');
      return;
    }
    final ok = await widget.controller.cancelLastSale(reason: _reason.text, supervisorCode: _code.text, supervisorPin: _pin.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      final notice = widget.controller.notice;
      _error = widget.controller.info?.startsWith('Sem resposta') ?? false
          ? widget.controller.info
          : (notice == null ? null : '${notice.message} ${notice.action}');
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.controller.lastSale;
    return PdvWindow(
      size: PdvWindowSize.compact,
      title: 'Cancelar a venda ${sale?.code ?? ''}',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        // Folga entre os campos: o rótulo de cima não encosta no texto.
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('A ${(widget.controller.cancelableNfce?.isNfe ?? false) ? 'NF-e' : 'NFC-e'} é cancelada na Sefaz e a venda é desfeita '
              '(estoque, pagamentos, cashback e crediário). Precisa de internet e da liberação de um supervisor.'),
          TextField(
            key: const Key('cancel-reason'),
            controller: _reason,
            autofocus: true,
            maxLength: 255,
            decoration: const InputDecoration(labelText: 'Motivo (mínimo 15 letras)'),
            onSubmitted: (_) => _codeFocus.requestFocus(),
          ),
          TextField(
            key: const Key('cancel-supervisor-code'),
            controller: _code,
            focusNode: _codeFocus,
            onSubmitted: (_) => _pinFocus.requestFocus(),
            decoration: const InputDecoration(labelText: 'Código do supervisor'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          TextField(
            key: const Key('cancel-supervisor-pin'),
            controller: _pin,
            focusNode: _pinFocus,
            obscureText: true,
            onSubmitted: (_) => _confirm(),
            decoration: const InputDecoration(labelText: 'PIN do supervisor'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const Key('cancel-error'))),
        ],
      ),
      actions: [
        const KeysHint(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
        FilledButton(
          key: const Key('cancel-confirm'),
          onPressed: widget.controller.busy ? null : _confirm,
          child: Text(widget.controller.busy ? 'Cancelando...' : 'Cancelar a venda'),
        ),
      ],
    );
  }
}

/// Pede o que falta para uma operação com permissão: quem está no terminal e tem a permissão só
/// confirma; quem não tem chama um supervisor (código e PIN). [onConfirm] recebe o código e o PIN
/// (vazios quando não precisa) e devolve true quando deu certo; o erro vem do aviso do controller.
class ReleaseDialog extends StatefulWidget {
  const ReleaseDialog({
    super.key,
    required this.controller,
    required this.title,
    required this.message,
    required this.needsSupervisor,
    required this.confirmLabel,
    required this.onConfirm,
    this.supervisorHint = 'Você não tem esta permissão: chame um supervisor para liberar.',
  });

  final PosController controller;
  final String title;
  final String message;
  final bool needsSupervisor;
  final String supervisorHint;
  final String confirmLabel;
  final Future<bool> Function(String code, String pin) onConfirm;

  @override
  State<ReleaseDialog> createState() => _ReleaseDialogState();
}

class _ReleaseDialogState extends State<ReleaseDialog> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();
  String? _error;
  bool _working = false;

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_working) return;
    setState(() => _working = true);
    final ok = await widget.onConfirm(_code.text, _pin.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
      return;
    }
    final notice = widget.controller.notice;
    setState(() {
      _working = false;
      _error = notice == null ? null : '${notice.message} ${notice.action}';
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PdvWindow(
      size: PdvWindowSize.compact,
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        // Folga entre os campos: o rótulo de cima não encosta no texto.
        spacing: 10,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message, key: const Key('release-message')),
          if (widget.needsSupervisor) ...[
            const SizedBox(height: 8),
            Text(widget.supervisorHint, key: const Key('release-hint')),
            TextField(
              key: const Key('release-code'),
              controller: _code,
              autofocus: true,
              onSubmitted: (_) => _pinFocus.requestFocus(),
              decoration: const InputDecoration(labelText: 'Código do supervisor'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            TextField(
              key: const Key('release-pin'),
              controller: _pin,
              focusNode: _pinFocus,
              obscureText: true,
              onSubmitted: (_) => _confirm(),
              decoration: const InputDecoration(labelText: 'PIN do supervisor'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            ),
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const Key('release-error'))),
        ],
      ),
      actions: [
        const KeysHint(),
        TextButton(key: const Key('release-back'), onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
        FilledButton(
          key: const Key('release-confirm'),
          autofocus: !widget.needsSupervisor,
          onPressed: _working ? null : _confirm,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// "Limpar tela" (orçamento) ou "Cancelar venda" (caixa e autoatendimento) da venda em andamento.
Future<void> showDiscardCartDialog(BuildContext context, PosController controller) {
  final cart = controller.cart;
  final count = cart.lines.length;
  final what = controller.quoteMode ? 'o orçamento em andamento' : 'a venda em andamento';
  return showDialog<bool>(
    context: context,
    builder: (_) => ReleaseDialog(
      controller: controller,
      title: controller.discardLabel,
      message: 'Descartar $what? ${count == 1 ? '1 item' : '$count itens'}, total ${formatCents(cart.totalCents)}. '
          'Os itens, o cliente e os pagamentos saem da tela.',
      needsSupervisor: controller.discardNeedsRelease,
      supervisorHint: controller.screen == 'self_service'
          ? 'No autoatendimento, o cancelamento precisa do código e do PIN de um responsável da loja.'
          : 'Você não tem esta permissão: chame um supervisor para liberar.',
      confirmLabel: controller.discardLabel,
      onConfirm: (code, pin) => controller.discardCart(supervisorCode: code, supervisorPin: pin),
    ),
  );
}

/// Liberação de um cadastro feito no PDV por quem não tem a permissão. Devolve o id de quem
/// liberou, ou null quando desistiu.
Future<String?> showRegistrationRelease(BuildContext context, PosController controller, {required String permission, required String what}) async {
  String? released;
  await showDialog<bool>(
    context: context,
    builder: (_) => ReleaseDialog(
      controller: controller,
      title: 'Liberar o cadastro',
      message: 'Cadastrar $what no PDV precisa de liberação.',
      needsSupervisor: true,
      confirmLabel: 'Liberar',
      onConfirm: (code, pin) async {
        released = (await controller.authorize(permission, code, pin))?.id;
        return released != null;
      },
    ),
  );
  return released;
}

/// Libera de uma vez os itens sem estoque que vieram dos orçamentos: código e PIN de quem tem
/// "Vender com estoque negativo".
Future<void> showStockReleaseDialog(BuildContext context, PosController controller) {
  final lines = controller.linesNeedingStockRelease;
  return showDialog<bool>(
    context: context,
    builder: (_) => ReleaseDialog(
      controller: controller,
      title: 'Liberar estoque negativo',
      message: [
        'Estes itens deixam o estoque negativo e precisam de liberação:',
        for (final line in lines) '• ${line.product.name} (saldo ${line.product.stockMilli < 0 ? '-' : ''}${formatMilli(line.product.stockMilli.abs())})',
      ].join('\n'),
      needsSupervisor: true,
      supervisorHint: 'Quem tem "Vender com estoque negativo" digita o código e o PIN.',
      confirmLabel: 'Liberar',
      onConfirm: (code, pin) => controller.releasePendingStock(code, pin),
    ),
  );
}
