import 'package:uuid/uuid.dart';

import 'pos_auth.dart';

/// Tipos de receita de controlado (Portaria 344/98 e RDC 471/2021). Os códigos são os da central.
enum PrescriptionType {
  notificationA('notification_a', 'Notificação A (amarela)'),
  notificationB('notification_b', 'Notificação B (azul)'),
  notificationB2('notification_b2', 'Notificação B2'),
  notificationRetinoid('notification_retinoid', 'Notificação de retinoide'),
  notificationThalidomide('notification_thalidomide', 'Notificação de talidomida'),
  specialControl('special_control', 'Receita de controle especial'),
  antimicrobial('antimicrobial', 'Receita de antimicrobiano');

  const PrescriptionType(this.code, this.label);

  final String code;
  final String label;

  bool get isNotification => code.startsWith('notification');

  /// Validade em dias, contados da data da receita: antimicrobiano 10, demais 30 (igual à central).
  int get validDays => this == antimicrobial ? 10 : 30;

  /// Tipo de receita da classe do produto (igual a app.prescription_type_for na central).
  static PrescriptionType forClass(String controlledClass) => switch (controlledClass) {
    'A1' || 'A2' || 'A3' => notificationA,
    'B1' => notificationB,
    'B2' => notificationB2,
    'C2' => notificationRetinoid,
    'C3' => notificationThalidomide,
    'antimicrobial' => antimicrobial,
    _ => specialControl,
  };
}

const prescriberCouncils = ['CRM', 'CRO', 'CRMV', 'COREN', 'CRF', 'RMS'];
const buyerDocumentTypes = {'rg': 'RG', 'cpf': 'CPF', 'cnh': 'CNH', 'passport': 'Passaporte', 'other': 'Outro'};
const brazilianStates = [
  'AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI', 'PR', 'RJ', 'RN',
  'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO',
];

/// Lote do controlado na cópia local, com o saldo que ainda sobra para esta venda.
class ControlledBatch {
  const ControlledBatch({required this.id, required this.number, required this.expiresOn, required this.availableMilli});

  final String id;
  final String number;
  final String expiresOn;
  final int availableMilli;
}

/// O que o balcão digita da receita, do prescritor, do comprador e do paciente.
class PrescriptionForm {
  PrescriptionForm({
    required this.type,
    this.number = '',
    this.date,
    this.prescriberName = '',
    this.prescriberCouncil = 'CRM',
    this.prescriberNumber = '',
    this.prescriberState = '',
    this.buyerName = '',
    this.buyerDocumentType = 'rg',
    this.buyerDocument = '',
    this.buyerIssuer = '',
    this.buyerState = '',
    this.patientName = '',
    this.patientAge,
    this.patientSex,
  });

  PrescriptionType type;
  String number;
  DateTime? date;
  String prescriberName;
  String prescriberCouncil;
  String prescriberNumber;
  String prescriberState;
  String buyerName;
  String buyerDocumentType;
  String buyerDocument;
  String buyerIssuer;
  String buyerState;
  String patientName;
  int? patientAge;
  String? patientSex;
}

final _prescriptionNumber = RegExp(r'^[0-9A-Za-z./-]{1,30}$');
final _councilNumber = RegExp(r'^[0-9A-Za-z-]{1,20}$');
final _document = RegExp(r'^[0-9A-Za-z./-]{3,30}$');

DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);

/// Campos com problema e o que dizer ao lado de cada um. Vazio: pode liberar.
/// As regras são as mesmas da tabela da central, para a venda não virar conflito.
Map<String, String> prescriptionErrors(PrescriptionForm form, DateTime today) {
  final errors = <String, String>{};
  bool name(String value) => value.trim().length >= 3 && value.trim().length <= 150;
  if (form.type.isNotification && !_prescriptionNumber.hasMatch(form.number.trim())) {
    errors['number'] = 'Informe o número da notificação';
  } else if (form.number.trim().isNotEmpty && !_prescriptionNumber.hasMatch(form.number.trim())) {
    errors['number'] = 'Use só letras, números, ponto, barra e hífen';
  }
  final date = form.date;
  if (date == null) {
    errors['date'] = 'Informe a data da receita';
  } else if (_day(date).isAfter(_day(today))) {
    errors['date'] = 'A data da receita está no futuro';
  } else if (_day(date).add(Duration(days: form.type.validDays)).isBefore(_day(today))) {
    errors['date'] = 'Receita vencida (vale ${form.type.validDays} dias)';
  }
  if (!name(form.prescriberName)) errors['prescriberName'] = 'Informe o nome do prescritor';
  if (!prescriberCouncils.contains(form.prescriberCouncil)) errors['prescriberCouncil'] = 'Escolha o conselho';
  if (!_councilNumber.hasMatch(form.prescriberNumber.trim())) errors['prescriberNumber'] = 'Informe o número no conselho';
  if (!brazilianStates.contains(form.prescriberState)) errors['prescriberState'] = 'Escolha a UF';
  if (!name(form.buyerName)) errors['buyerName'] = 'Informe o nome do comprador';
  if (!buyerDocumentTypes.containsKey(form.buyerDocumentType)) errors['buyerDocumentType'] = 'Escolha o documento';
  if (!_document.hasMatch(form.buyerDocument.trim())) errors['buyerDocument'] = 'Informe o número do documento';
  final issuer = form.buyerIssuer.trim();
  if (issuer.length < 2 || issuer.length > 20) errors['buyerIssuer'] = 'Informe o órgão emissor';
  if (!brazilianStates.contains(form.buyerState)) errors['buyerState'] = 'Escolha a UF';
  if (form.patientName.trim().isNotEmpty && !name(form.patientName)) errors['patientName'] = 'Nome do paciente muito curto';
  final age = form.patientAge;
  if (age != null && (age < 0 || age > 130)) errors['patientAge'] = 'Idade inválida';
  if (form.type == PrescriptionType.antimicrobial) {
    if (age == null) errors['patientAge'] = 'Informe a idade do paciente';
    if (form.patientSex == null) errors['patientSex'] = 'Informe o sexo do paciente';
  }
  return errors;
}

/// Liberação do controlado que vai com o item: completa (receita e lote) ou pendente (estoque negativo).
class ControlledRelease {
  ControlledRelease._({
    required this.id,
    required this.pharmacistId,
    required this.pharmacistName,
    this.form,
    this.batch,
    this.pendingReason,
  });

  /// Venda com receita, comprador e lote. Confere os campos (FA986) e a data (FA987).
  factory ControlledRelease.complete({
    required PrescriptionForm form,
    required ControlledBatch batch,
    required LocalUserRef pharmacist,
    required DateTime today,
  }) {
    final errors = prescriptionErrors(form, today);
    if (errors.containsKey('date') && form.date != null) throw const PosException('FA987');
    if (errors.isNotEmpty) throw const PosException('FA986');
    return ControlledRelease._(
      id: const Uuid().v7(),
      pharmacistId: pharmacist.id,
      pharmacistName: pharmacist.name,
      form: form,
      batch: batch,
    );
  }

  /// Venda liberada sem saldo em lote: os dados do SNGPC são completados depois, na retaguarda.
  factory ControlledRelease.pending({required String reason, required LocalUserRef pharmacist}) {
    final text = reason.trim();
    if (text.isEmpty || text.length > 500) throw const PosException('FA986');
    return ControlledRelease._(
      id: const Uuid().v7(),
      pharmacistId: pharmacist.id,
      pharmacistName: pharmacist.name,
      pendingReason: text,
    );
  }

  final String id;
  final String pharmacistId;
  final String pharmacistName;
  final PrescriptionForm? form;
  final ControlledBatch? batch;
  final String? pendingReason;

  bool get isPending => pendingReason != null;

  /// Objeto que sobe com o item da venda. Tem dados pessoais: vai só pela outbox, nunca para o log.
  Map<String, Object?> toJson() {
    final data = form;
    if (data == null) {
      return {'id': id, 'status': 'pending', 'pharmacist_id': pharmacistId, 'pending_reason': pendingReason};
    }
    String? optional(String value) => value.trim().isEmpty ? null : value.trim();
    final date = data.date!;
    return {
      'id': id,
      'status': 'complete',
      'pharmacist_id': pharmacistId,
      'prescription_type': data.type.code,
      'prescription_number': optional(data.number),
      'prescription_date':
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      'prescriber_name': data.prescriberName.trim(),
      'prescriber_council': data.prescriberCouncil,
      'prescriber_number': data.prescriberNumber.trim(),
      'prescriber_state': data.prescriberState,
      'buyer_name': data.buyerName.trim(),
      'buyer_document_type': data.buyerDocumentType,
      'buyer_document': data.buyerDocument.trim(),
      'buyer_issuer': data.buyerIssuer.trim(),
      'buyer_state': data.buyerState,
      'patient_name': optional(data.patientName),
      'patient_age': data.patientAge,
      'patient_sex': data.patientSex,
    };
  }
}

/// Quem liberou (só o que o item precisa guardar).
typedef LocalUserRef = ({String id, String name});
