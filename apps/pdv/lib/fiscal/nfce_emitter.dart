import 'package:uuid/uuid.dart';

import '../core/local_logger.dart';
import '../local/local_database.dart';
import '../pos/cart.dart';
import 'access_key.dart';
import 'nfce.dart';
import 'nfce_credentials.dart';
import 'sefaz.dart';
import 'xml_signer.dart';

/// Resultado da emissão para o caixa: a nota (quando chegou a ser montada) e o aviso ao operador.
class NfceOutcome {
  const NfceOutcome({this.nfce, this.noticeCode, this.detail});

  /// Nota montada e assinada: autorizada, recusada ou pendente (sem resposta da Sefaz).
  final LocalNfce? nfce;

  /// Aviso quando a nota não saiu autorizada: FA736 recusada, FA739 em contingência, FA737 sem
  /// resposta e sem contingência, FA738 sem certificado, FA723 a FA726 dados fiscais. A venda é concluída mesmo assim (nota pendente).
  final String? noticeCode;

  /// Motivo técnico, só para o log.
  final String? detail;

  bool get authorized => nfce?.authorized ?? false;
}

/// Forma de pagamento da venda para o tPag da NFC-e.
NfcePayment nfcePayment(Payment payment) => switch (payment.method) {
  PaymentMethod.cash => NfcePayment(type: '01', cents: payment.amountCents),
  PaymentMethod.creditCard => NfcePayment(type: '03', cents: payment.amountCents),
  PaymentMethod.debitCard => NfcePayment(type: '04', cents: payment.amountCents),
  PaymentMethod.pix => NfcePayment(type: '17', cents: payment.amountCents),
  // Crediário, convênio e crédito de devolução: crédito na própria loja.
  PaymentMethod.storeCredit || PaymentMethod.agreement || PaymentMethod.returnCredit =>
    NfcePayment(type: '05', cents: payment.amountCents),
  PaymentMethod.cashback => NfcePayment(type: '99', cents: payment.amountCents, description: 'Cashback'),
};

/// Motivo da contingência que vai na nota (xJust, 15 a 256 caracteres).
const contingencyReason = 'Sem comunicacao com a Sefaz no momento da venda';

/// Emite a NFC-e da venda no caixa, direto na Sefaz da UF. Sem resposta da Sefaz, a nota sai em
/// contingência offline (tpEmis 9), com o mesmo número, e é transmitida depois. Nunca impede a
/// venda: o que der errado vira aviso.
class NfceEmitter {
  NfceEmitter({
    required this.database,
    required this.credentials,
    required this.sefaz,
    required this.terminalId,
    required this.appVersion,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final NfceCredentialService credentials;
  final SefazClient sefaz;
  final String? Function() terminalId;
  final String appVersion;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  /// A filial emite NFC-e neste caixa.
  bool get enabled => credentials.enabled;

  Future<NfceOutcome?> emit({required String saleId, required Cart cart}) async {
    if (!enabled) return null;
    final now = _clock();
    final terminal = terminalId();
    final opened = terminal == null ? null : await _credentials(terminal);
    if (opened == null) return const NfceOutcome(noticeCode: 'FA738');
    NfceDocument build({required ({int series, int number}) numbering, int emissionType = 1}) {
      final issuer = NfceIssuer.fromFiscal(database.fiscal!);
      return buildNfce(
        NfceInput(
          issuer: issuer,
          items: [for (final line in cart.lines) _item(line, now)],
          payments: [for (final payment in cart.payments) nfcePayment(payment)],
          changeCents: cart.changeCents,
          series: numbering.series,
          number: numbering.number,
          emittedAt: now,
          environment: credentials.environment,
          emissionType: emissionType,
          contingencyAt: emissionType == 9 ? now : null,
          contingencyReason: emissionType == 9 ? contingencyReason : null,
          numericCode: randomNumericCode(numbering.number),
          appVersion: appVersion,
          customerCpf: _customerCpf(cart),
          csc: Csc(id: opened.cscId, token: opened.csc),
        ),
        SigningCredential.fromPem(privateKeyPem: opened.privateKeyPem, certificatePem: opened.certificatePem),
      );
    }

    late NfceDocument document;
    final ({int series, int number}) numbering;
    try {
      if (database.fiscal == null) throw const FiscalException('FA724', 'Sem dados fiscais da filial.');
      final next = database.nextNfceNumber();
      if (next == null) throw const FiscalException('FA724', 'Caixa sem série do modelo 65.');
      numbering = next;
      document = build(numbering: next);
    } on FiscalException catch (error) {
      logger?.warn('NFC-e não montada', fields: {'error_code': error.code, 'err': error.detail});
      return NfceOutcome(noticeCode: error.code, detail: error.detail);
    }

    final result = await sefaz.authorize(
      signedNfe: document.xml,
      uf: (database.fiscal!['branch'] as Map)['state'] as String,
      environment: credentials.environment,
      credentials: opened,
    );
    LocalNfce nfce({required String status, String? protocol, String? statusCode, String? reason, String? xml, DateTime? authorizedAt, int emissionType = 1}) =>
        LocalNfce(
          id: const Uuid().v7(),
          saleId: saleId,
          series: numbering.series,
          number: numbering.number,
          accessKey: document.accessKey,
          environment: credentials.environment,
          emissionType: emissionType,
          status: status,
          protocol: protocol,
          statusCode: statusCode,
          reason: reason,
          xml: xml ?? document.xml,
          qrCode: document.qrCode,
          consultUrl: document.consultUrl,
          emittedAt: now,
          authorizedAt: authorizedAt,
        );
    // Só a chave e a situação no log: nada de dados do cliente.
    switch (result) {
      case SefazAuthorized():
        logger?.info('NFC-e autorizada', fields: {'number': numbering.number, 'series': numbering.series, 'status_code': result.statusCode});
        return NfceOutcome(
          nfce: nfce(
            status: 'authorized',
            protocol: result.protocol,
            statusCode: result.statusCode,
            reason: result.reason,
            xml: result.procXml,
            authorizedAt: result.authorizedAt,
          ),
        );
      case SefazRejected():
        logger?.warn('NFC-e recusada pela Sefaz', fields: {'number': numbering.number, 'status_code': result.statusCode});
        return NfceOutcome(
          nfce: nfce(status: 'rejected', statusCode: result.statusCode, reason: result.reason),
          noticeCode: 'FA736',
          detail: '${result.statusCode} ${result.reason}',
        );
      case SefazDuplicate() || SefazCanceled() || SefazNotFound():
        // A Sefaz já tem esta nota (a resposta de antes se perdeu): fica pendente com a mesma chave
        // e a retransmissão consulta e pega o protocolo. (Cancelada e "não consta" só vêm da consulta.)
        logger?.warn('NFC-e já recebida pela Sefaz; consultar depois', fields: {'number': numbering.number});
        return NfceOutcome(nfce: nfce(status: 'pending', reason: 'A Sefaz já recebeu esta nota; falta o protocolo.'));
      case SefazUnavailable():
        // Contingência offline: a mesma numeração, outra chave (tpEmis 9) e o QR Code com o digest.
        logger?.warn('NFC-e em contingência', fields: {'number': numbering.number, 'err': result.reason});
        try {
          document = build(numbering: numbering, emissionType: 9);
        } on FiscalException catch (error) {
          return NfceOutcome(nfce: nfce(status: 'pending', reason: result.reason), noticeCode: 'FA737', detail: error.detail);
        }
        return NfceOutcome(
          nfce: nfce(status: 'contingency', reason: result.reason, emissionType: 9),
          noticeCode: 'FA739',
          detail: result.reason,
        );
    }
  }

  Future<NfceCredentials?> _credentials(String terminal) async {
    try {
      return await credentials.credentials(terminalId: terminal);
    } on NfceCredentialException {
      return null;
    }
  }

  NfceItem _item(CartLine line, DateTime now) {
    final data = database.nfceProductData(line.product.id, now);
    final ncm = data?.ncm;
    final tax = data?.tax;
    if (ncm == null || ncm.isEmpty) throw FiscalException('FA726', 'Produto ${line.product.code} sem NCM.');
    if (tax == null) throw FiscalException('FA723', 'Produto ${line.product.code} sem tributação.');
    return NfceItem(
      code: '${line.product.code}',
      gtin: data!.gtin,
      description: line.product.name,
      ncm: ncm,
      cest: data.cest,
      unit: data.unit,
      quantityMilli: line.quantityMilli,
      unitPriceCents: line.unitPriceCents,
      grossCents: line.grossCents,
      discountCents: line.discountCents,
      tax: tax,
    );
  }

  /// CPF do cliente identificado na venda, quando é pessoa física.
  String? _customerCpf(Cart cart) {
    final customer = cart.customer;
    if (customer == null) return null;
    final document = database.customerById(customer.id)?['document'] as String?;
    return document != null && document.length == 11 ? document : null;
  }
}
