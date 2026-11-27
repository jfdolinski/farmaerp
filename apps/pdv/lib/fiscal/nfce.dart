import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

import 'access_key.dart';
import 'nfce_urls.dart';
import 'xml_signer.dart';

part 'nfe.dart';

const _nfeNamespace = 'http://www.portalfiscal.inf.br/nfe';
/// Textos obrigatórios em homologação: no primeiro item (xProd) e no nome do destinatário (até 60).
const homologationText = 'NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL';
const homologationRecipient = 'NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL';

/// Nota que não dá para montar: o código vai para o operador (catálogo de erros) e o detalhe para o log.
class FiscalException implements Exception {
  const FiscalException(this.code, this.detail);

  final String code;
  final String detail;

  @override
  String toString() => 'FiscalException($code, $detail)';
}

/// Emitente: a filial e a empresa, como descem da central.
class NfceIssuer {
  const NfceIssuer({
    required this.cnpj,
    required this.stateRegistration,
    required this.legalName,
    required this.tradeName,
    required this.street,
    required this.number,
    this.complement,
    required this.district,
    required this.cityCode,
    required this.city,
    required this.uf,
    required this.postalCode,
    this.phone,
    required this.taxRegime,
  });

  /// A partir de `database.fiscal` (branch e company). Falta de dado obrigatório é FA724.
  factory NfceIssuer.fromFiscal(Map<String, dynamic> fiscal) {
    final branch = (fiscal['branch'] as Map?)?.cast<String, dynamic>() ?? const {};
    final company = (fiscal['company'] as Map?)?.cast<String, dynamic>() ?? const {};
    String need(Map<String, dynamic> source, String field) {
      final value = (source[field] as Object?)?.toString().trim() ?? '';
      if (value.isEmpty) throw FiscalException('FA724', 'Filial sem $field.');
      return value;
    }

    return NfceIssuer(
      cnpj: need(branch, 'cnpj'),
      stateRegistration: need(branch, 'state_registration'),
      legalName: need(company, 'legal_name'),
      tradeName: (company['trade_name'] as String?) ?? need(company, 'legal_name'),
      street: need(branch, 'street'),
      number: need(branch, 'street_number'),
      complement: branch['complement'] as String?,
      district: need(branch, 'district'),
      cityCode: need(branch, 'city_code'),
      city: need(branch, 'city'),
      uf: need(branch, 'state'),
      postalCode: need(branch, 'postal_code'),
      phone: branch['phone'] as String?,
      taxRegime: (company['tax_regime'] as num?)?.toInt() ?? (throw const FiscalException('FA724', 'Empresa sem regime.')),
    );
  }

  final String cnpj;
  final String stateRegistration;
  final String legalName;
  final String tradeName;
  final String street;
  final String number;
  final String? complement;
  final String district;
  final String cityCode;
  final String city;
  final String uf;
  final String postalCode;
  final String? phone;

  /// CRT: 1 Simples, 2 Simples com excesso de sublimite, 3 normal, 4 MEI.
  final int taxRegime;

  bool get simples => taxRegime == 1 || taxRegime == 4;
}

class NfceItem {
  const NfceItem({
    required this.code,
    this.gtin,
    required this.description,
    required this.ncm,
    this.cest,
    this.unit = 'UN',
    required this.quantityMilli,
    required this.unitPriceCents,
    required this.grossCents,
    this.discountCents = 0,
    required this.tax,
    this.freightCents = 0,
    this.insuranceCents = 0,
    this.otherCents = 0,
    this.ipiReturnedCents = 0,
    this.returnPercent,
  });

  final String code;
  final String? gtin;
  final String description;
  final String ncm;
  final String? cest;

  /// Unidade de medida do produto (UN, CX, KG...): vai em uCom e uTrib.
  final String unit;
  final int quantityMilli;
  final int unitPriceCents;
  final int grossCents;
  final int discountCents;

  /// Tributação em vigor do produto (como desce do catálogo).
  final Map<String, dynamic> tax;

  /// Só na NF-e: frete, seguro e outras despesas do item (entram na base do ICMS e no total).
  final int freightCents;
  final int insuranceCents;
  final int otherCents;

  /// Só na NF-e de devolução: IPI devolvido do item e o percentual da mercadoria devolvida.
  final int ipiReturnedCents;
  final num? returnPercent;

  /// Valor do item na base dos impostos: produtos menos desconto, mais frete, seguro e outras.
  int get taxBaseCents => grossCents - discountCents + freightCents + insuranceCents + otherCents;
}

class NfcePayment {
  const NfcePayment({required this.type, required this.cents, this.description});

  /// tPag: 01 dinheiro, 03 crédito, 04 débito, 05 crédito loja, 17 PIX, 99 outros.
  final String type;
  final int cents;
  final String? description;
}

/// Código do CSC da Sefaz (QR Code versão 2).
class Csc {
  const Csc({required this.id, required this.token});

  final String id;
  final String token;
}

class NfceInput {
  const NfceInput({
    required this.issuer,
    required this.items,
    required this.payments,
    this.changeCents = 0,
    required this.series,
    required this.number,
    required this.emittedAt,
    required this.environment,
    this.emissionType = 1,
    this.contingencyAt,
    this.contingencyReason,
    required this.numericCode,
    required this.appVersion,
    this.customerCpf,
    required this.csc,
    this.ibsCbs = false,
  });

  final NfceIssuer issuer;
  final List<NfceItem> items;
  final List<NfcePayment> payments;
  final int changeCents;
  final int series;
  final int number;
  final DateTime emittedAt;

  /// tpAmb: 1 produção, 2 homologação.
  final int environment;

  /// tpEmis: 1 normal, 9 contingência offline.
  final int emissionType;
  final DateTime? contingencyAt;
  final String? contingencyReason;
  final String numericCode;
  final String appVersion;
  final String? customerCpf;
  final Csc csc;

  /// Grupo IBS/CBS da reforma tributária (ligado por empresa quando o contador confirmar).
  final bool ibsCbs;
}

/// Nota montada e assinada.
class NfceDocument {
  const NfceDocument({required this.accessKey, required this.xml, required this.qrCode, required this.consultUrl, required this.totalCents});

  final String accessKey;
  final String xml;
  final String qrCode;
  final String consultUrl;
  final int totalCents;
}

String money(int cents) {
  final negative = cents < 0;
  final value = cents.abs();
  return '${negative ? '-' : ''}${value ~/ 100}.${(value % 100).toString().padLeft(2, '0')}';
}

String _quantity(int milli) => '${milli ~/ 1000}.${(milli % 1000).toString().padLeft(3, '0')}0';

/// Alíquota com 4 casas (o leiaute aceita de 2 a 4).
String _rate(num value) => value.toStringAsFixed(4);

int _percentOf(int cents, num rate) => (cents * rate / 100).round();

/// Data e hora no fuso de Brasília (UTC-3), no formato do leiaute.
String brasiliaTime(DateTime instant) {
  final local = instant.toUtc().subtract(const Duration(hours: 3));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}T${two(local.hour)}:${two(local.minute)}:${two(local.second)}-03:00';
}

String _hexSha1(String text) =>
    SHA1Digest().process(Uint8List.fromList(utf8.encode(text))).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _hexOfText(String text) => utf8.encode(text).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Parâmetros do QR Code versão 2 (com o CSC). Online: chave|2|tpAmb|idCSC|hash. Contingência:
/// chave|2|tpAmb|dia|vNF|digVal(hex)|idCSC|hash. O hash é o SHA-1 dos parâmetros com o CSC no fim.
String qrCodeV2({
  required String key,
  required int environment,
  required Csc csc,
  required int emissionType,
  DateTime? emittedAt,
  int? totalCents,
  String? digestValue,
}) {
  final cscId = int.parse(csc.id).toString();
  final fields = emissionType == 9
      ? [
          key,
          '2',
          '$environment',
          brasiliaTime(emittedAt!).substring(8, 10),
          money(totalCents!),
          _hexOfText(digestValue!),
          cscId,
        ].join('|')
      : [key, '2', '$environment', cscId].join('|');
  return '$fields|${_hexSha1('$fields${csc.token}')}';
}

class _Taxes {
  int icmsBase = 0;
  int icms = 0;
  int pis = 0;
  int cofins = 0;
  int ibsCbsBase = 0;
  int ibsState = 0;
  int ibsCity = 0;
  int cbs = 0;
}

/// Monta a NFC-e (leiaute 4.00), assina e gera o QR Code.
NfceDocument buildNfce(NfceInput input, SigningCredential credential) {
  final issuer = input.issuer;
  final urls = nfceUrls(issuer.uf, input.environment);
  if (urls == null || !ufCodes.containsKey(issuer.uf)) throw FiscalException('FA725', 'UF ${issuer.uf} ainda não atendida.');
  if (input.items.isEmpty) throw const FiscalException('FA726', 'Nota sem itens.');
  if (input.emissionType == 9 && (input.contingencyAt == null || (input.contingencyReason ?? '').trim().length < 15)) {
    throw const FiscalException('FA726', 'Contingência sem data ou justificativa de 15 caracteres.');
  }
  final key = accessKey(
    uf: issuer.uf,
    emittedAt: input.emittedAt.toUtc().subtract(const Duration(hours: 3)),
    cnpj: issuer.cnpj,
    model: 65,
    series: input.series,
    number: input.number,
    emissionType: input.emissionType,
    numericCode: input.numericCode,
  );
  final homologation = input.environment == 2;
  final totals = _Taxes();
  var productsCents = 0;
  var discountCents = 0;

  final b = XmlBuilder();
  b.element('NFe', nest: () {
    b.attribute('xmlns', _nfeNamespace);
    b.element('infNFe', nest: () {
      b.attribute('Id', 'NFe$key');
      b.attribute('versao', '4.00');
      b.element('ide', nest: () {
        b.element('cUF', nest: ufCodes[issuer.uf]);
        b.element('cNF', nest: input.numericCode);
        b.element('natOp', nest: 'VENDA');
        b.element('mod', nest: '65');
        b.element('serie', nest: '${input.series}');
        b.element('nNF', nest: '${input.number}');
        b.element('dhEmi', nest: brasiliaTime(input.emittedAt));
        b.element('tpNF', nest: '1');
        b.element('idDest', nest: '1');
        b.element('cMunFG', nest: issuer.cityCode);
        b.element('tpImp', nest: '4');
        b.element('tpEmis', nest: '${input.emissionType}');
        b.element('cDV', nest: key.substring(43));
        b.element('tpAmb', nest: '${input.environment}');
        b.element('finNFe', nest: '1');
        b.element('indFinal', nest: '1');
        b.element('indPres', nest: '1');
        b.element('procEmi', nest: '0');
        b.element('verProc', nest: 'FarmaERP ${input.appVersion}');
        if (input.emissionType == 9) {
          b.element('dhCont', nest: brasiliaTime(input.contingencyAt!));
          b.element('xJust', nest: input.contingencyReason!.trim());
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
          final phone = (issuer.phone ?? '').replaceAll(RegExp(r'\D'), '');
          if (phone.length >= 6 && phone.length <= 14) b.element('fone', nest: phone);
        });
        b.element('IE', nest: issuer.stateRegistration);
        b.element('CRT', nest: '${issuer.taxRegime}');
      });
      final cpf = input.customerCpf?.replaceAll(RegExp(r'\D'), '');
      if (cpf != null && cpf.length == 11) {
        b.element('dest', nest: () {
          b.element('CPF', nest: cpf);
          if (homologation) b.element('xNome', nest: homologationRecipient);
          b.element('indIEDest', nest: '9');
        });
      }
      for (var index = 0; index < input.items.length; index += 1) {
        final item = input.items[index];
        productsCents += item.grossCents;
        discountCents += item.discountCents;
        _item(b, index + 1, item, issuer, (ibsCbs: input.ibsCbs), homologation && index == 0, totals);
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
          b.element('vFrete', nest: '0.00');
          b.element('vSeg', nest: '0.00');
          b.element('vDesc', nest: money(discountCents));
          b.element('vII', nest: '0.00');
          b.element('vIPI', nest: '0.00');
          b.element('vIPIDevol', nest: '0.00');
          b.element('vPIS', nest: money(totals.pis));
          b.element('vCOFINS', nest: money(totals.cofins));
          b.element('vOutro', nest: '0.00');
          b.element('vNF', nest: money(productsCents - discountCents));
        });
        if (input.ibsCbs) _ibsCbsTotal(b, totals);
      });
      b.element('transp', nest: () => b.element('modFrete', nest: '9'));
      b.element('pag', nest: () {
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
        if (input.changeCents > 0) b.element('vTroco', nest: money(input.changeCents));
      });
    });
  });

  final document = b.buildDocument();
  final nfe = document.rootElement;
  final infNFe = nfe.getElement('infNFe')!;
  final total = productsCents - discountCents;
  final qrParameters = qrCodeV2(
    key: key,
    environment: input.environment,
    csc: input.csc,
    emissionType: input.emissionType,
    emittedAt: input.emittedAt,
    totalCents: total,
    digestValue: input.emissionType == 9 ? digestOf(infNFe) : null,
  );
  final qrCode = '${urls.qrCode}?p=$qrParameters';
  nfe.children.add(XmlElement(XmlName.parts('infNFeSupl'), [], [
    XmlElement(XmlName.parts('qrCode'), [], [XmlText(qrCode)]),
    XmlElement(XmlName.parts('urlChave'), [], [XmlText(urls.consult)]),
  ]));
  signEnveloped(parent: nfe, signed: infNFe, credential: credential);
  return NfceDocument(
    accessKey: key,
    xml: document.toXmlString(),
    qrCode: qrCode,
    consultUrl: urls.consult,
    totalCents: total,
  );
}

void _item(XmlBuilder b, int line, NfceItem item, NfceIssuer issuer, ({bool ibsCbs}) input, bool homologationName, _Taxes totals) {
  final tax = item.tax;
  final base = item.taxBaseCents;
  final gtin = item.gtin != null && RegExp(r'^(\d{8}|\d{12,14})$').hasMatch(item.gtin!) ? item.gtin! : 'SEM GTIN';
  b.element('det', nest: () {
    b.attribute('nItem', '$line');
    b.element('prod', nest: () {
      b.element('cProd', nest: item.code);
      b.element('cEAN', nest: gtin);
      b.element('xProd', nest: homologationName ? homologationText : item.description.trim());
      b.element('NCM', nest: item.ncm);
      if (item.cest != null && item.cest!.isNotEmpty) b.element('CEST', nest: item.cest);
      b.element('CFOP', nest: tax['cfop'] as String);
      b.element('uCom', nest: item.unit);
      b.element('qCom', nest: _quantity(item.quantityMilli));
      b.element('vUnCom', nest: money(item.unitPriceCents));
      b.element('vProd', nest: money(item.grossCents));
      b.element('cEANTrib', nest: gtin);
      b.element('uTrib', nest: item.unit);
      b.element('qTrib', nest: _quantity(item.quantityMilli));
      b.element('vUnTrib', nest: money(item.unitPriceCents));
      // Ordem do leiaute: frete, seguro, desconto, outras.
      if (item.freightCents > 0) b.element('vFrete', nest: money(item.freightCents));
      if (item.insuranceCents > 0) b.element('vSeg', nest: money(item.insuranceCents));
      if (item.discountCents > 0) b.element('vDesc', nest: money(item.discountCents));
      if (item.otherCents > 0) b.element('vOutro', nest: money(item.otherCents));
      b.element('indTot', nest: '1');
    });
    b.element('imposto', nest: () {
      b.element('ICMS', nest: () => _icms(b, tax, base, issuer, totals, item));
      _contribution(b, 'PIS', tax['pis_cst'] as String, (tax['pis_rate'] as num?) ?? 0, base, (value) => totals.pis += value, item);
      _contribution(b, 'COFINS', tax['cofins_cst'] as String, (tax['cofins_rate'] as num?) ?? 0, base, (value) => totals.cofins += value, item);
      if (input.ibsCbs) _ibsCbs(b, tax, base, totals, item);
    });
    // Devolução: o IPI que volta ao fornecedor.
    if (item.ipiReturnedCents > 0) {
      b.element('impostoDevol', nest: () {
        b.element('pDevol', nest: (item.returnPercent ?? 100).clamp(0, 100).toStringAsFixed(2));
        b.element('IPI', nest: () => b.element('vIPIDevol', nest: money(item.ipiReturnedCents)));
      });
    }
  });
}

void _icms(XmlBuilder b, Map<String, dynamic> tax, int base, NfceIssuer issuer, _Taxes totals, NfceItem item) {
  final origin = '${tax['origin']}';
  if (issuer.simples) {
    final csosn = tax['icms_csosn'] as String?;
    switch (csosn) {
      case '102' || '103' || '300' || '400':
        b.element('ICMSSN102', nest: () {
          b.element('orig', nest: origin);
          b.element('CSOSN', nest: csosn);
        });
      case '500':
        b.element('ICMSSN500', nest: () {
          b.element('orig', nest: origin);
          b.element('CSOSN', nest: csosn);
        });
      default:
        throw FiscalException('FA723', 'CSOSN $csosn não atendido na NFC-e (item ${item.code}).');
    }
    return;
  }
  final cst = tax['icms_cst'] as String?;
  switch (cst) {
    case '00' || '20':
      final rate = (tax['icms_rate'] as num?) ?? (throw FiscalException('FA723', 'CST $cst sem alíquota (item ${item.code}).'));
      final reduction = (tax['icms_base_reduction'] as num?) ?? 0;
      final icmsBase = cst == '20' ? (base * (100 - reduction) / 100).round() : base;
      final value = _percentOf(icmsBase, rate);
      totals.icmsBase += icmsBase;
      totals.icms += value;
      b.element('ICMS$cst', nest: () {
        b.element('orig', nest: origin);
        b.element('CST', nest: cst);
        b.element('modBC', nest: '3');
        if (cst == '20') b.element('pRedBC', nest: _rate(reduction));
        b.element('vBC', nest: money(icmsBase));
        b.element('pICMS', nest: _rate(rate));
        b.element('vICMS', nest: money(value));
      });
    case '40' || '41' || '50':
      b.element('ICMS40', nest: () {
        b.element('orig', nest: origin);
        b.element('CST', nest: cst);
      });
    case '60':
      b.element('ICMS60', nest: () {
        b.element('orig', nest: origin);
        b.element('CST', nest: cst);
      });
    default:
      throw FiscalException('FA723', 'CST $cst não atendido na NFC-e (item ${item.code}).');
  }
}

void _contribution(XmlBuilder b, String name, String cst, num rate, int base, void Function(int) add, NfceItem item) {
  b.element(name, nest: () {
    switch (cst) {
      case '01' || '02' || '49' || '99':
        final value = _percentOf(base, rate);
        add(value);
        b.element(cst == '01' || cst == '02' ? '${name}Aliq' : '${name}Outr', nest: () {
          b.element('CST', nest: cst);
          b.element('vBC', nest: money(base));
          b.element('p$name', nest: _rate(rate));
          b.element('v$name', nest: money(value));
        });
      case '04' || '05' || '06' || '07' || '08' || '09':
        b.element('${name}NT', nest: () => b.element('CST', nest: cst));
      default:
        throw FiscalException('FA723', 'CST de $name $cst não atendido na NFC-e (item ${item.code}).');
    }
  });
}

void _ibsCbs(XmlBuilder b, Map<String, dynamic> tax, int base, _Taxes totals, NfceItem item) {
  final cst = tax['ibs_cbs_cst'] as String?;
  final classTrib = tax['class_trib'] as String?;
  if (cst == null || classTrib == null) throw FiscalException('FA723', 'Produto sem CST ou cClassTrib do IBS/CBS (item ${item.code}).');
  final stateRate = (tax['ibs_state_rate'] as num?) ?? 0;
  final cityRate = (tax['ibs_city_rate'] as num?) ?? 0;
  final cbsRate = (tax['cbs_rate'] as num?) ?? 0;
  final stateValue = _percentOf(base, stateRate);
  final cityValue = _percentOf(base, cityRate);
  final cbsValue = _percentOf(base, cbsRate);
  totals.ibsCbsBase += base;
  totals.ibsState += stateValue;
  totals.ibsCity += cityValue;
  totals.cbs += cbsValue;
  b.element('IBSCBS', nest: () {
    b.element('CST', nest: cst);
    b.element('cClassTrib', nest: classTrib);
    b.element('gIBSCBS', nest: () {
      b.element('vBC', nest: money(base));
      b.element('gIBSUF', nest: () {
        b.element('pIBSUF', nest: _rate(stateRate));
        b.element('vIBSUF', nest: money(stateValue));
      });
      b.element('gIBSMun', nest: () {
        b.element('pIBSMun', nest: _rate(cityRate));
        b.element('vIBSMun', nest: money(cityValue));
      });
      b.element('vIBS', nest: money(stateValue + cityValue));
      b.element('gCBS', nest: () {
        b.element('pCBS', nest: _rate(cbsRate));
        b.element('vCBS', nest: money(cbsValue));
      });
    });
  });
}

void _ibsCbsTotal(XmlBuilder b, _Taxes totals) {
  b.element('IBSCBSTot', nest: () {
    b.element('vBCIBSCBS', nest: money(totals.ibsCbsBase));
    b.element('gIBS', nest: () {
      b.element('gIBSUF', nest: () {
        b.element('vDif', nest: '0.00');
        b.element('vDevTrib', nest: '0.00');
        b.element('vIBSUF', nest: money(totals.ibsState));
      });
      b.element('gIBSMun', nest: () {
        b.element('vDif', nest: '0.00');
        b.element('vDevTrib', nest: '0.00');
        b.element('vIBSMun', nest: money(totals.ibsCity));
      });
      b.element('vIBS', nest: money(totals.ibsState + totals.ibsCity));
      b.element('vCredPres', nest: '0.00');
      b.element('vCredPresCondSus', nest: '0.00');
    });
    b.element('gCBS', nest: () {
      b.element('vDif', nest: '0.00');
      b.element('vDevTrib', nest: '0.00');
      b.element('vCBS', nest: money(totals.cbs));
      b.element('vCredPres', nest: '0.00');
      b.element('vCredPresCondSus', nest: '0.00');
    });
  });
}
