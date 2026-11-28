import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farmaerp_pdv/fiscal/danfe_a4.dart';
import 'package:farmaerp_pdv/fiscal/nfce.dart';
import 'package:farmaerp_pdv/fiscal/xml_signer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'nfce_test.dart' show issuerSimples, normalTax, schemaErrors, simplesTax, testCredential;

/// NF-e modelo 55: mesmo motor da NFC-e, com destinatário completo, finalidade e referências.
const company = NfeRecipient(
  cnpj: '33.444.555/0001-81',
  name: 'DROGARIA CLIENTE LTDA',
  ieIndicator: 1,
  stateRegistration: '110.042.490.114',
  street: 'Avenida Paulista',
  number: '1000',
  complement: 'Sala 2',
  district: 'Bela Vista',
  cityCode: '3550308',
  city: 'São Paulo',
  uf: 'SP',
  postalCode: '01310-100',
  phone: '(11) 4444-5555',
  email: 'compras@cliente.test',
);

const supplierPr = NfeRecipient(
  cnpj: '44555666000199',
  name: 'DISTRIBUIDORA FORNECEDORA LTDA',
  ieIndicator: 1,
  stateRegistration: '9012345678',
  street: 'Rua XV de Novembro',
  number: '50',
  district: 'Centro',
  cityCode: '4106902',
  city: 'Curitiba',
  uf: 'PR',
  postalCode: '80020310',
);

const purchaseKey = '41261144555666000199550010000012341000012345';

NfceItem item({Map<String, dynamic> tax = normalTax, int freight = 0, int insurance = 0, int other = 0, int ipiReturned = 0, num? percent}) => NfceItem(
  code: '1', gtin: '7890000000017', description: 'Dipirona Sódica 500 mg', ncm: '30049099', cest: '1300100', unit: 'CX',
  quantityMilli: 2000, unitPriceCents: 1000, grossCents: 2000, discountCents: 100, tax: tax,
  freightCents: freight, insuranceCents: insurance, otherCents: other, ipiReturnedCents: ipiReturned, returnPercent: percent,
);

NfeInput sale({NfeRecipient recipient = company, List<NfceItem>? items, int environment = 2, NfceIssuer issuer = const NfceIssuer(
  cnpj: '11222333000181', stateRegistration: '110042490114', legalName: 'FARMACIA DEMONSTRACAO LTDA', tradeName: 'Farmácia Demonstração',
  street: 'Rua das Flores & Cia', number: '100', district: 'Centro', cityCode: '3550308', city: 'São Paulo', uf: 'SP',
  postalCode: '01001000', phone: '(11) 3333-4444', taxRegime: 3,
)}) => NfeInput(
  issuer: issuer,
  recipient: recipient,
  items: items ?? [item()],
  payments: const [NfcePayment(type: '17', cents: 1900)],
  series: 1,
  number: 77,
  emittedAt: DateTime.utc(2026, 11, 27, 15, 0, 0),
  environment: environment,
  numericCode: '87654321',
  appVersion: '0.3.0',
  operation: 'VENDA',
);

NfeInput devolution({List<NfceItem>? items, List<String> references = const [purchaseKey]}) => NfeInput(
  issuer: issuerSimples,
  recipient: supplierPr,
  items: items ??
      [
        item(tax: {...simplesTax, 'cfop': '6202'}, freight: 50, insurance: 20, other: 30, ipiReturned: 120, percent: 50),
      ],
  series: 1,
  number: 78,
  emittedAt: DateTime.utc(2026, 11, 27, 16, 0, 0),
  environment: 2,
  numericCode: '11223344',
  appVersion: '0.3.0',
  operation: 'DEVOLUCAO DE COMPRA',
  purpose: 4,
  presence: 0,
  references: references,
  additionalInfo: 'Devolução da NF-e 1234 série 1:   embalagem avariada.',
);

String text(XmlDocument doc, String name) => doc.findAllElements(name).first.innerText;

void main() {
  test('venda para empresa contribuinte: modelo 55, destinatário completo e válida no schema oficial', () async {
    final nfe = buildNfe(sale(), testCredential());
    expect(nfe.accessKey, hasLength(44));
    expect(nfe.accessKey.substring(20, 22), '55');
    final doc = XmlDocument.parse(nfe.xml);
    expect(text(doc, 'mod'), '55');
    expect(text(doc, 'natOp'), 'VENDA');
    expect(text(doc, 'idDest'), '1');
    expect(text(doc, 'tpImp'), '1');
    expect(text(doc, 'indFinal'), '0');
    expect(text(doc, 'indPres'), '1');
    expect(text(doc, 'finNFe'), '1');
    final dest = doc.findAllElements('dest').single;
    expect(dest.getElement('CNPJ')!.innerText, '33444555000181');
    expect(dest.getElement('xNome')!.innerText, homologationRecipient);
    expect(dest.getElement('indIEDest')!.innerText, '1');
    expect(dest.getElement('IE')!.innerText, '110042490114');
    expect(dest.getElement('email')!.innerText, 'compras@cliente.test');
    expect(dest.findAllElements('CEP').single.innerText, '01310100');
    expect(dest.findAllElements('xCpl').single.innerText, 'Sala 2');
    // Na NF-e o nome do produto vai como está (o texto de homologação é só da NFC-e).
    expect(text(doc, 'xProd'), 'Dipirona Sódica 500 mg');
    expect(doc.findAllElements('infNFeSupl'), isEmpty);
    expect(doc.findAllElements('tPag').single.innerText, '17');
    // ICMS 18% sobre 19,00 e o total.
    expect(text(doc, 'vICMS'), '3.42');
    expect(doc.findAllElements('ICMSTot').single.getElement('vNF')!.innerText, '19.00');
    expect(nfe.totalCents, 1900);
    final signature = doc.findAllElements('Signature').single;
    expect(signature.findAllElements('DigestValue').single.innerText, digestOf(doc.findAllElements('infNFe').single));
    expect(signature.findAllElements('Reference').single.getAttribute('URI'), '#NFe${nfe.accessKey}');
    expect(await schemaErrors(nfe.xml), isEmpty);
  });

  test('contingência SVC: tpEmis na chave e na nota, com a hora e o motivo no lugar certo; válida no schema oficial', () async {
    NfeInput svc({int emissionType = 6, DateTime? at, String? reason = 'Sefaz da UF sem comunicacao no momento da emissao'}) {
      final base = sale();
      return NfeInput(
        issuer: base.issuer, recipient: base.recipient, items: base.items, payments: base.payments, series: base.series,
        number: base.number, emittedAt: base.emittedAt, environment: base.environment, numericCode: base.numericCode,
        appVersion: base.appVersion, operation: base.operation, emissionType: emissionType,
        contingencyAt: at ?? DateTime.utc(2026, 11, 27, 15, 0, 0), contingencyReason: reason,
      );
    }

    final nfe = buildNfe(svc(), testCredential());
    expect(nfe.accessKey.substring(34, 35), '6');
    final doc = XmlDocument.parse(nfe.xml);
    expect(text(doc, 'tpEmis'), '6');
    expect(text(doc, 'dhCont'), '2026-11-27T12:00:00-03:00');
    expect(text(doc, 'xJust'), 'Sefaz da UF sem comunicacao no momento da emissao');
    final ide = doc.findAllElements('ide').single.childElements.map((e) => e.name.local).toList();
    expect(ide.indexOf('dhCont'), ide.indexOf('verProc') + 1);
    expect(await schemaErrors(nfe.xml), isEmpty);
    // A normal continua com 1 e sem os campos da contingência.
    final normal = XmlDocument.parse(buildNfe(sale(), testCredential()).xml);
    expect(text(normal, 'tpEmis'), '1');
    expect(normal.findAllElements('dhCont'), isEmpty);

    // Recusas: SVC de outra região (SP é SVC-AN), forma desconhecida, sem hora ou motivo curto.
    for (final input in [svc(emissionType: 7), svc(emissionType: 9), svc(reason: 'curto'), svc(reason: null)]) {
      expect(() => buildNfe(input, testCredential()), throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA726')));
    }
  });

  test('em produção, o nome verdadeiro do destinatário; pessoa física não contribuinte é consumidor final', () async {
    const person = NfeRecipient(
      cpf: '529.982.247-25', name: 'CLIENTE PESSOA FISICA', ieIndicator: 9, street: 'Rua A', number: '1', district: 'Centro',
      cityCode: '3550308', city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    );
    final doc = XmlDocument.parse(buildNfe(sale(recipient: person, environment: 1), testCredential()).xml);
    final dest = doc.findAllElements('dest').single;
    expect(dest.getElement('CPF')!.innerText, '52998224725');
    expect(dest.getElement('xNome')!.innerText, 'CLIENTE PESSOA FISICA');
    expect(dest.getElement('IE'), isNull);
    expect(text(doc, 'indFinal'), '1');
    expect(await schemaErrors(buildNfe(sale(recipient: person, environment: 1), testCredential()).xml), isEmpty);
  });

  test('outra UF é interestadual: CFOP 6xxx; 5xxx para fora do estado é recusado', () async {
    final interstate = buildNfe(sale(recipient: supplierPr, items: [item(tax: {...normalTax, 'cfop': '6102'})]), testCredential());
    expect(text(XmlDocument.parse(interstate.xml), 'idDest'), '2');
    expect(await schemaErrors(interstate.xml), isEmpty);
    expect(() => buildNfe(sale(recipient: supplierPr), testCredential()), throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA723')));
    expect(() => buildNfe(sale(items: [item(tax: {...normalTax, 'cfop': '6102'})]), testCredential()),
        throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA723')));
  });

  test('devolução de compra: finalidade 4, nota referenciada, frete, seguro, outras e IPI devolvido, sem pagamento', () async {
    final nfe = buildNfe(devolution(), testCredential());
    final doc = XmlDocument.parse(nfe.xml);
    expect(text(doc, 'finNFe'), '4');
    expect(text(doc, 'indPres'), '0');
    expect(text(doc, 'idDest'), '2');
    expect(text(doc, 'natOp'), 'DEVOLUCAO DE COMPRA');
    expect(doc.findAllElements('refNFe').single.innerText, purchaseKey);
    final prod = doc.findAllElements('prod').single;
    expect(prod.childElements.map((e) => e.name.local).skipWhile((n) => n != 'vUnTrib').skip(1).toList(),
        ['vFrete', 'vSeg', 'vDesc', 'vOutro', 'indTot']);
    final devol = doc.findAllElements('impostoDevol').single;
    expect(devol.getElement('pDevol')!.innerText, '50.00');
    expect(devol.findAllElements('vIPIDevol').single.innerText, '1.20');
    final totals = doc.findAllElements('ICMSTot').single;
    expect(totals.getElement('vFrete')!.innerText, '0.50');
    expect(totals.getElement('vSeg')!.innerText, '0.20');
    expect(totals.getElement('vOutro')!.innerText, '0.30');
    expect(totals.getElement('vIPIDevol')!.innerText, '1.20');
    // 20,00 − 1,00 + 0,50 + 0,20 + 0,30 + 1,20
    expect(totals.getElement('vNF')!.innerText, '21.20');
    expect(nfe.totalCents, 2120);
    final pay = doc.findAllElements('detPag').single;
    expect(pay.getElement('tPag')!.innerText, '90');
    expect(pay.getElement('vPag')!.innerText, '0.00');
    expect(text(doc, 'infCpl'), 'Devolução da NF-e 1234 série 1: embalagem avariada.');
    expect(await schemaErrors(nfe.xml), isEmpty);
  });

  test('regime normal: frete, seguro e outras despesas entram na base do ICMS', () async {
    final nfe = buildNfe(sale(items: [item(freight: 100, insurance: 50, other: 50)]), testCredential());
    final doc = XmlDocument.parse(nfe.xml);
    // 20,00 − 1,00 + 1,00 + 0,50 + 0,50 = 21,00; ICMS 18% = 3,78.
    expect(doc.findAllElements('ICMS00').single.getElement('vBC')!.innerText, '21.00');
    expect(text(doc, 'vICMS'), '3.78');
    expect(doc.findAllElements('ICMSTot').single.getElement('vNF')!.innerText, '21.00');
    expect(await schemaErrors(nfe.xml), isEmpty);
  });

  test('DANFE A4: PDF da nota, com protocolo ou sem; muitos itens viram mais folhas', () async {
    int pages(Uint8List pdf) => RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;
    final nfe = buildNfe(devolution(), testCredential());
    final pdf = await buildDanfeA4(nfe.xml);
    expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
    expect(pages(pdf), 1);
    // Com o protocolo (nfeProc) também monta.
    final proc = '<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">${nfe.xml.replaceFirst(RegExp(r'^<\?xml[^>]*>'), '')}'
        '<protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${nfe.accessKey}</chNFe><dhRecbto>2026-11-27T13:00:05-03:00</dhRecbto>'
        '<nProt>135260000000999</nProt><cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe></nfeProc>';
    expect(pages(await buildDanfeA4(proc)), 1);
    final many = buildNfe(sale(items: [for (var i = 0; i < 90; i += 1) item()]), testCredential());
    expect(pages(await buildDanfeA4(many.xml)), greaterThan(1));
    // Para conferir o visual: DANFE_OUT=caminho.pdf grava um exemplo.
    final out = Platform.environment['DANFE_OUT'];
    if (out != null) File(out).writeAsBytesSync(await buildDanfeA4(proc));
  });

  test('o que não dá para montar vira código do catálogo', () {
    void refused(NfeInput input, String code) =>
        expect(() => buildNfe(input, testCredential()), throwsA(isA<FiscalException>().having((e) => e.code, 'code', code)), reason: code);
    refused(devolution(references: const []), 'FA726');
    refused(devolution(references: const ['123']), 'FA726');
    refused(sale(items: const []), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      cnpj: '33444555000181', cpf: '52998224725', name: 'X', ieIndicator: 9, street: 'R', number: '1', district: 'C',
      cityCode: '3550308', city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    )), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      name: 'X', ieIndicator: 9, street: 'R', number: '1', district: 'C', cityCode: '3550308', city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    )), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      cnpj: '33444555000181', name: 'X', ieIndicator: 1, street: 'R', number: '1', district: 'C', cityCode: '3550308',
      city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    )), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      cnpj: '33444555000181', name: 'X', ieIndicator: 9, street: ' ', number: '1', district: 'C', cityCode: '3550308',
      city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    )), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      cnpj: '33444555000181', name: 'X', ieIndicator: 9, street: 'R', number: '1', district: 'C', cityCode: '3550308',
      city: 'São Paulo', uf: 'XX', postalCode: '01001000',
    )), 'FA726');
    refused(sale(recipient: const NfeRecipient(
      cnpj: '33444555000181', name: 'X', ieIndicator: 3, street: 'R', number: '1', district: 'C', cityCode: '3550308',
      city: 'São Paulo', uf: 'SP', postalCode: '01001000',
    )), 'FA726');
  });
}
