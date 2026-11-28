part of 'nfce.dart';

/// Destinatário da NF-e (modelo 55): empresa (CNPJ) ou pessoa (CPF), com endereço completo.
class NfeRecipient {
  const NfeRecipient({
    this.cnpj,
    this.cpf,
    required this.name,
    required this.ieIndicator,
    this.stateRegistration,
    required this.street,
    required this.number,
    this.complement,
    required this.district,
    required this.cityCode,
    required this.city,
    required this.uf,
    required this.postalCode,
    this.phone,
    this.email,
  });

  final String? cnpj;
  final String? cpf;
  final String name;

  /// indIEDest: 1 contribuinte do ICMS (com IE), 2 isento, 9 não contribuinte.
  final int ieIndicator;
  final String? stateRegistration;
  final String street;
  final String number;
  final String? complement;
  final String district;
  final String cityCode;
  final String city;
  final String uf;
  final String postalCode;
  final String? phone;
  final String? email;
}

/// Dados da NF-e modelo 55. Mesmo emitente, itens e tributação da NFC-e; muda o destinatário,
/// a natureza da operação, a finalidade e o que vai junto (notas referenciadas, transporte).
class NfeInput {
  const NfeInput({
    required this.issuer,
    required this.recipient,
    required this.items,
    this.payments = const [],
    required this.series,
    required this.number,
    required this.emittedAt,
    required this.environment,
    required this.numericCode,
    required this.appVersion,
    required this.operation,
    this.purpose = 1,
    this.presence = 1,
    this.finalConsumer,
    this.references = const [],
    this.freightMode = 9,
    this.additionalInfo,
    this.ibsCbs = false,
    this.emissionType = 1,
    this.contingencyAt,
    this.contingencyReason,
  });

  final NfceIssuer issuer;
  final NfeRecipient recipient;
  final List<NfceItem> items;

  /// Formas de pagamento; vazio é "sem pagamento" (tPag 90), como na devolução e na transferência.
  final List<NfcePayment> payments;
  final int series;
  final int number;
  final DateTime emittedAt;

  /// tpAmb: 1 produção, 2 homologação.
  final int environment;
  final String numericCode;
  final String appVersion;

  /// natOp: "VENDA", "DEVOLUCAO DE COMPRA", "TRANSFERENCIA"...
  final String operation;

  /// finNFe: 1 normal, 4 devolução.
  final int purpose;

  /// indPres: 1 presencial (venda no caixa), 0 não se aplica (devolução, transferência).
  final int presence;

  /// indFinal: vazio segue o destinatário (não contribuinte é consumidor final).
  final bool? finalConsumer;

  /// Chaves das notas referenciadas (a de compra, na devolução).
  final List<String> references;

  /// modFrete: 0 emitente, 1 destinatário, 9 sem frete.
  final int freightMode;

  /// Informações complementares (infCpl).
  final String? additionalInfo;
  final bool ibsCbs;

  /// tpEmis: 1 normal; 6 SVC-AN e 7 SVC-RS (contingência na Sefaz Virtual, com a hora e o motivo).
  final int emissionType;
  final DateTime? contingencyAt;

  /// xJust: de 15 a 256 caracteres.
  final String? contingencyReason;
}

/// Sefaz Virtual de Contingência da UF: 6 SVC-AN ou 7 SVC-RS (NT 2013.007). Null: UF fora da tabela.
int? svcEmissionType(String uf) {
  const rs = {'AM', 'BA', 'CE', 'GO', 'MA', 'MS', 'MT', 'PA', 'PE', 'PI', 'PR'};
  const an = {'AC', 'AL', 'AP', 'DF', 'ES', 'MG', 'PB', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'};
  if (rs.contains(uf)) return 7;
  if (an.contains(uf)) return 6;
  return null;
}

/// NF-e montada e assinada.
class NfeDocument {
  const NfeDocument({required this.accessKey, required this.xml, required this.totalCents});

  final String accessKey;
  final String xml;
  final int totalCents;
}

String _digits(String? value) => (value ?? '').replaceAll(RegExp(r'\D'), '');

/// Monta a NF-e modelo 55 (leiaute 4.00) e assina. Mesmo motor da NFC-e para itens e impostos.
NfeDocument buildNfe(NfeInput input, SigningCredential credential) {
  final issuer = input.issuer;
  final recipient = input.recipient;
  if (!ufCodes.containsKey(issuer.uf)) throw FiscalException('FA725', 'UF ${issuer.uf} ainda não atendida.');
  if (input.items.isEmpty) throw const FiscalException('FA726', 'Nota sem itens.');
  if (![1, 6, 7].contains(input.emissionType)) throw FiscalException('FA726', 'Forma de emissão ${input.emissionType} não atendida.');
  if (input.emissionType != 1) {
    final reason = (input.contingencyReason ?? '').trim();
    if (input.contingencyAt == null || reason.length < 15 || reason.length > 256) {
      throw const FiscalException('FA726', 'Contingência sem a hora ou o motivo (15 a 256 caracteres).');
    }
    if (svcEmissionType(issuer.uf) != input.emissionType) {
      throw FiscalException('FA726', 'SVC ${input.emissionType} não atende a UF ${issuer.uf}.');
    }
  }
  if (input.purpose != 1 && input.purpose != 4) throw FiscalException('FA726', 'Finalidade ${input.purpose} não atendida.');
  if (input.purpose == 4 && input.references.isEmpty) throw const FiscalException('FA726', 'Devolução sem a nota referenciada.');
  for (final reference in input.references) {
    if (!RegExp(r'^\d{44}$').hasMatch(reference)) throw FiscalException('FA726', 'Chave referenciada inválida: $reference.');
  }
  final cnpj = _digits(recipient.cnpj);
  final cpf = _digits(recipient.cpf);
  if ((cnpj.length == 14) == (cpf.length == 11)) throw const FiscalException('FA726', 'Destinatário precisa de CNPJ ou CPF (só um).');
  if (recipient.name.trim().isEmpty) throw const FiscalException('FA726', 'Destinatário sem nome.');
  if (!ufCodes.containsKey(recipient.uf)) throw FiscalException('FA726', 'UF do destinatário inválida: ${recipient.uf}.');
  if (![1, 2, 9].contains(recipient.ieIndicator)) throw FiscalException('FA726', 'Indicador da IE ${recipient.ieIndicator}.');
  final ie = _digits(recipient.stateRegistration);
  if (recipient.ieIndicator == 1 && ie.isEmpty) throw const FiscalException('FA726', 'Destinatário contribuinte sem IE.');
  for (final field in [recipient.street, recipient.number, recipient.district, recipient.cityCode, recipient.city, recipient.postalCode]) {
    if (field.trim().isEmpty) throw const FiscalException('FA726', 'Endereço do destinatário incompleto.');
  }

  // Mesma UF: operação interna (CFOP 5xxx); outra UF: interestadual (6xxx).
  final interstate = recipient.uf != issuer.uf;
  for (final item in input.items) {
    final cfop = '${item.tax['cfop']}';
    final expected = interstate ? '6' : '5';
    if (cfop.length != 4 || cfop[0] != expected) {
      throw FiscalException('FA723', 'CFOP $cfop não combina com a operação ${interstate ? 'interestadual' : 'interna'} (item ${item.code}).');
    }
  }

  final key = accessKey(
    uf: issuer.uf,
    emittedAt: input.emittedAt.toUtc().subtract(const Duration(hours: 3)),
    cnpj: issuer.cnpj,
    model: 55,
    series: input.series,
    number: input.number,
    emissionType: input.emissionType,
    numericCode: input.numericCode,
  );
  final homologation = input.environment == 2;
  final finalConsumer = input.finalConsumer ?? recipient.ieIndicator == 9;
  final totals = _Taxes();
  var productsCents = 0, discountCents = 0, freightCents = 0, insuranceCents = 0, otherCents = 0, ipiReturnedCents = 0;

  final b = XmlBuilder();
  b.element('NFe', nest: () {
    b.attribute('xmlns', _nfeNamespace);
    b.element('infNFe', nest: () {
      b.attribute('Id', 'NFe$key');
      b.attribute('versao', '4.00');
      b.element('ide', nest: () {
        b.element('cUF', nest: ufCodes[issuer.uf]);
        b.element('cNF', nest: input.numericCode);
        b.element('natOp', nest: input.operation.trim());
        b.element('mod', nest: '55');
        b.element('serie', nest: '${input.series}');
        b.element('nNF', nest: '${input.number}');
        b.element('dhEmi', nest: brasiliaTime(input.emittedAt));
        b.element('tpNF', nest: '1');
        b.element('idDest', nest: interstate ? '2' : '1');
        b.element('cMunFG', nest: issuer.cityCode);
        // DANFE retrato.
        b.element('tpImp', nest: '1');
        b.element('tpEmis', nest: '${input.emissionType}');
        b.element('cDV', nest: key.substring(43));
        b.element('tpAmb', nest: '${input.environment}');
        b.element('finNFe', nest: '${input.purpose}');
        b.element('indFinal', nest: finalConsumer ? '1' : '0');
        b.element('indPres', nest: '${input.presence}');
        b.element('procEmi', nest: '0');
        b.element('verProc', nest: 'FarmaERP ${input.appVersion}');
        if (input.emissionType != 1) {
          b.element('dhCont', nest: brasiliaTime(input.contingencyAt!));
          b.element('xJust', nest: input.contingencyReason!.trim());
        }
        for (final reference in input.references) {
          b.element('NFref', nest: () => b.element('refNFe', nest: reference));
        }
      });
      b.element('emit', nest: () {
        b.element('CNPJ', nest: issuer.cnpj);
        b.element('xNome', nest: issuer.legalName);
        b.element('xFant', nest: issuer.tradeName);
        b.element('enderEmit', nest: () {
          b.element('xLgr', nest: issuer.street);
          b.element('nro', nest: issuer.number);
          if ((issuer.complement ?? '').trim().isNotEmpty) b.element('xCpl', nest: issuer.complement!.trim());
          b.element('xBairro', nest: issuer.district);
          b.element('cMun', nest: issuer.cityCode);
          b.element('xMun', nest: issuer.city);
          b.element('UF', nest: issuer.uf);
          b.element('CEP', nest: issuer.postalCode);
          b.element('cPais', nest: '1058');
          b.element('xPais', nest: 'Brasil');
          final phone = _digits(issuer.phone);
          if (phone.length >= 6 && phone.length <= 14) b.element('fone', nest: phone);
        });
        b.element('IE', nest: issuer.stateRegistration);
        b.element('CRT', nest: '${issuer.taxRegime}');
      });
      b.element('dest', nest: () {
        if (cnpj.length == 14) {
          b.element('CNPJ', nest: cnpj);
        } else {
          b.element('CPF', nest: cpf);
        }
        b.element('xNome', nest: homologation ? homologationRecipient : recipient.name.trim());
        b.element('enderDest', nest: () {
          b.element('xLgr', nest: recipient.street.trim());
          b.element('nro', nest: recipient.number.trim());
          if ((recipient.complement ?? '').trim().isNotEmpty) b.element('xCpl', nest: recipient.complement!.trim());
          b.element('xBairro', nest: recipient.district.trim());
          b.element('cMun', nest: recipient.cityCode.trim());
          b.element('xMun', nest: recipient.city.trim());
          b.element('UF', nest: recipient.uf);
          b.element('CEP', nest: _digits(recipient.postalCode));
          b.element('cPais', nest: '1058');
          b.element('xPais', nest: 'Brasil');
          final phone = _digits(recipient.phone);
          if (phone.length >= 6 && phone.length <= 14) b.element('fone', nest: phone);
        });
        b.element('indIEDest', nest: '${recipient.ieIndicator}');
        if (recipient.ieIndicator == 1) b.element('IE', nest: ie);
        final email = (recipient.email ?? '').trim();
        if (email.contains('@') && email.length <= 60) b.element('email', nest: email);
      });
      for (var index = 0; index < input.items.length; index += 1) {
        final item = input.items[index];
        productsCents += item.grossCents;
        discountCents += item.discountCents;
        freightCents += item.freightCents;
        insuranceCents += item.insuranceCents;
        otherCents += item.otherCents;
        ipiReturnedCents += item.ipiReturnedCents;
        _item(b, index + 1, item, issuer, (ibsCbs: input.ibsCbs), false, totals);
      }
      b.element('total', nest: () {
        b.element('ICMSTot', nest: () {
          b.element('vBC', nest: money(totals.icmsBase));
          b.element('vICMS', nest: money(totals.icms));
          b.element('vICMSDeson', nest: '0.00');
          b.element('vFCP', nest: '0.00');
          b.element('vBCST', nest: '0.00');
          b.element('vST', nest: '0.00');
          b.element('vFCPST', nest: '0.00');
          b.element('vFCPSTRet', nest: '0.00');
          b.element('vProd', nest: money(productsCents));
          b.element('vFrete', nest: money(freightCents));
          b.element('vSeg', nest: money(insuranceCents));
          b.element('vDesc', nest: money(discountCents));
          b.element('vII', nest: '0.00');
          b.element('vIPI', nest: '0.00');
          b.element('vIPIDevol', nest: money(ipiReturnedCents));
          b.element('vPIS', nest: money(totals.pis));
          b.element('vCOFINS', nest: money(totals.cofins));
          b.element('vOutro', nest: money(otherCents));
          b.element('vNF', nest: money(_nfeTotal(productsCents, discountCents, freightCents, insuranceCents, otherCents, ipiReturnedCents)));
        });
        if (input.ibsCbs) _ibsCbsTotal(b, totals);
      });
      b.element('transp', nest: () => b.element('modFrete', nest: '${input.freightMode}'));
      b.element('pag', nest: () {
        if (input.payments.isEmpty) {
          b.element('detPag', nest: () {
            b.element('tPag', nest: '90');
            b.element('vPag', nest: '0.00');
          });
        }
        for (final payment in input.payments) {
          b.element('detPag', nest: () {
            b.element('tPag', nest: payment.type);
            if (payment.type == '99') b.element('xPag', nest: (payment.description ?? 'Outros').trim());
            b.element('vPag', nest: money(payment.cents));
            if (payment.type == '03' || payment.type == '04' || payment.type == '17') {
              b.element('card', nest: () => b.element('tpIntegra', nest: '2'));
            }
          });
        }
      });
      final info = (input.additionalInfo ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (info.isNotEmpty) {
        b.element('infAdic', nest: () => b.element('infCpl', nest: info.length > 5000 ? info.substring(0, 5000) : info));
      }
    });
  });

  final document = b.buildDocument();
  final nfe = document.rootElement;
  signEnveloped(parent: nfe, signed: nfe.getElement('infNFe')!, credential: credential);
  return NfeDocument(
    accessKey: key,
    xml: document.toXmlString(),
    totalCents: _nfeTotal(productsCents, discountCents, freightCents, insuranceCents, otherCents, ipiReturnedCents),
  );
}

/// vNF = produtos − desconto + frete + seguro + outras + IPI devolvido (sem ST e IPI próprios aqui).
int _nfeTotal(int products, int discount, int freight, int insurance, int other, int ipiReturned) =>
    products - discount + freight + insurance + other + ipiReturned;
