import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farmaerp_pdv/fiscal/access_key.dart';
import 'package:farmaerp_pdv/fiscal/nfce.dart';
import 'package:farmaerp_pdv/fiscal/xml_c14n.dart';
import 'package:farmaerp_pdv/fiscal/xml_signer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

/// Certificado e chave só de teste (autoassinado, sem dados de ninguém).
SigningCredential testCredential() => SigningCredential.fromPem(
  privateKeyPem: File('test/fixtures/fiscal/test-key.pem').readAsStringSync(),
  certificatePem: File('test/fixtures/fiscal/test-cert.pem').readAsStringSync(),
);

const issuerSimples = NfceIssuer(
  cnpj: '11222333000181',
  stateRegistration: '110042490114',
  legalName: 'FARMACIA DEMONSTRACAO LTDA',
  tradeName: 'Farmácia Demonstração',
  street: 'Rua das Flores & Cia',
  number: '100',
  district: 'Centro',
  cityCode: '3550308',
  city: 'São Paulo',
  uf: 'SP',
  postalCode: '01001000',
  phone: '(11) 3333-4444',
  taxRegime: 1,
);

const simplesTax = {'cfop': '5405', 'origin': 0, 'icms_csosn': '500', 'pis_cst': '04', 'cofins_cst': '04'};
const normalTax = {
  'cfop': '5102', 'origin': 0, 'icms_cst': '00', 'icms_rate': 18, 'pis_cst': '01', 'pis_rate': 0.65,
  'cofins_cst': '01', 'cofins_rate': 3, 'ibs_cbs_cst': '000', 'class_trib': '000001', 'ibs_state_rate': 0.1,
  'ibs_city_rate': 0, 'cbs_rate': 0.9,
};

NfceInput input({
  NfceIssuer issuer = issuerSimples,
  Map<String, dynamic> tax = simplesTax,
  int emissionType = 1,
  int environment = 2,
  String? cpf,
  bool ibsCbs = false,
  String firstUnit = 'UN',
}) => NfceInput(
  issuer: issuer,
  items: [
    NfceItem(
      code: '1', gtin: '7890000000017', description: 'Dipirona Sódica 500 mg', ncm: '30049099', cest: '1300100',
      unit: firstUnit,
      quantityMilli: 2000, unitPriceCents: 1290, grossCents: 2580, discountCents: 80, tax: tax,
    ),
    NfceItem(code: '2', description: 'Soro <fisiológico>', ncm: '30049099', quantityMilli: 1000, unitPriceCents: 500, grossCents: 500, tax: tax),
  ],
  payments: const [NfcePayment(type: '01', cents: 2000), NfcePayment(type: '03', cents: 1100)],
  changeCents: 100,
  series: 1,
  number: 123,
  emittedAt: DateTime.utc(2026, 11, 26, 15, 30, 5),
  environment: environment,
  emissionType: emissionType,
  contingencyAt: emissionType == 9 ? DateTime.utc(2026, 11, 26, 15, 0) : null,
  contingencyReason: emissionType == 9 ? 'Sem conexão com a internet no momento da venda' : null,
  numericCode: '12345678',
  appVersion: '0.3.0',
  customerCpf: cpf,
  csc: const Csc(id: '000001', token: 'CSC-SO-DE-TESTE-0123456789'),
  ibsCbs: ibsCbs,
);

/// Valida com os schemas oficiais (PL_010h) pelo .NET do PowerShell. Sem PowerShell, o teste avisa e passa.
Future<List<String>> schemaErrors(String xml) async {
  final shell = Platform.isWindows ? 'powershell' : 'pwsh';
  final file = File('${Directory.systemTemp.createTempSync('nfce-').path}/nota.xml')..writeAsStringSync(xml);
  try {
    final result = await Process.run(shell, [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tool/validate-xsd.ps1',
      '-Schema', 'test/fixtures/schemas/PL_010h_v1.03/nfe_v4.00.xsd', '-Xml', file.path,
    ]);
    if (result.exitCode == 0) return [];
    return '${result.stdout}${result.stderr}'.trim().split('\n');
  } on ProcessException {
    markTestSkipped('PowerShell indisponível: validação de schema não rodou.');
    return [];
  }
}

void main() {
  test('chave de acesso: 44 dígitos com o dígito verificador do módulo 11', () {
    // Só o último dígito vale 1: soma 1×2 = 2, resto 2, DV = 11 - 2 = 9. Resto 0 ou 1 dá DV 0.
    expect(accessKeyDigit('${'0' * 42}1'), 9);
    expect(accessKeyDigit('0' * 43), 0);
    final key = accessKey(
      uf: 'SP', emittedAt: DateTime(2026, 11), cnpj: '11222333000181', model: 65, series: 1, number: 123,
      emissionType: 1, numericCode: '12345678',
    );
    expect(key, hasLength(44));
    expect(key.substring(0, 6), '352611');
    expect(int.parse(key[43]), accessKeyDigit(key.substring(0, 43)));
    expect(randomNumericCode(12345678), isNot('12345678'));
  });

  test('canonicalização: namespace herdado no elemento, atributos em ordem e texto escapado', () {
    final doc = XmlDocument.parse('<a xmlns="urn:x"><b z="1" a="&quot;2&quot;">x &amp; y &gt; z<c/></b></a>');
    expect(canonicalize(doc.rootElement.getElement('b')!), '<b xmlns="urn:x" a="&quot;2&quot;" z="1">x &amp; y &gt; z<c></c></b>');
  });

  test('Simples (CSOSN 500): valida no schema oficial, totais e homologação', () async {
    final doc = buildNfce(input(cpf: '529.982.247-25'), testCredential());
    expect(await schemaErrors(doc.xml), isEmpty);
    final xml = XmlDocument.parse(doc.xml);
    String text(String name) => xml.findAllElements(name).first.innerText;
    expect(text('vProd'), '25.80');
    expect(xml.findAllElements('vNF').single.innerText, '30.00');
    expect(xml.findAllElements('vDesc').last.innerText, '0.80');
    expect(xml.findAllElements('xProd').first.innerText, homologationText);
    expect(xml.findAllElements('xProd').last.innerText, 'Soro <fisiológico>');
    expect(xml.findAllElements('CPF').single.innerText, '52998224725');
    expect(xml.findAllElements('vTroco').single.innerText, '1.00');
    expect(doc.totalCents, 3000);
    expect(doc.accessKey.substring(20, 22), '65');
  });

  test('regime normal (CST 00, PIS e COFINS com alíquota) e IBS/CBS ligado: valida no schema oficial', () async {
    const normal = NfceIssuer(
      cnpj: '11222333000181', stateRegistration: '110042490114', legalName: 'FARMACIA NORMAL SA', tradeName: 'Normal',
      street: 'Rua A', number: '1', district: 'Centro', cityCode: '4106902', city: 'Curitiba', uf: 'PR',
      postalCode: '80010000', taxRegime: 3,
    );
    final plain = buildNfce(input(issuer: normal, tax: normalTax), testCredential());
    expect(await schemaErrors(plain.xml), isEmpty);
    final xml = XmlDocument.parse(plain.xml);
    // ICMS: 18% de 25,00 + 18% de 5,00.
    expect(xml.findAllElements('vICMS').last.innerText, '5.40');
    // PIS: 0,65% de 25,00 (0,16) + de 5,00 (0,03).
    expect(xml.findAllElements('vPIS').last.innerText, '0.19');
    expect(xml.findAllElements('IBSCBS'), isEmpty);
    final reform = buildNfce(input(issuer: normal, tax: normalTax, ibsCbs: true), testCredential());
    expect(await schemaErrors(reform.xml), isEmpty);
    // CBS: 0,9% de 25,00 (0,23) + de 5,00 (0,05).
    expect(XmlDocument.parse(reform.xml).findAllElements('vCBS').last.innerText, '0.28');
  });

  test('assinatura: o resumo e a assinatura conferem com a chave pública do certificado', () {
    final doc = buildNfce(input(), testCredential());
    final xml = XmlDocument.parse(doc.xml);
    final infNFe = xml.findAllElements('infNFe').single;
    final signature = xml.findAllElements('Signature').single;
    expect(signature.getAttribute('xmlns'), 'http://www.w3.org/2000/09/xmldsig#');
    expect(signature.findAllElements('DigestValue').single.innerText, digestOf(infNFe));
    expect(signature.findAllElements('Reference').single.getAttribute('URI'), '#NFe${doc.accessKey}');
    // Confere a assinatura com a chave pública do certificado de teste.
    final signedInfo = signature.getElement('SignedInfo')!;
    final value = base64.decode(signature.getElement('SignatureValue')!.innerText);
    final certificate = ASN1Parser(Uint8List.fromList(base64.decode(signature.findAllElements('X509Certificate').single.innerText)))
        .nextObject() as ASN1Sequence;
    final tbs = certificate.elements![0] as ASN1Sequence;
    final spki = tbs.elements!.whereType<ASN1Sequence>().firstWhere((s) => s.elements!.length == 2 && s.elements![1] is ASN1BitString);
    final rsa = ASN1Parser((spki.elements![1] as ASN1BitString).stringValues as Uint8List).nextObject() as ASN1Sequence;
    final publicKey = RSAPublicKey((rsa.elements![0] as ASN1Integer).integer!, (rsa.elements![1] as ASN1Integer).integer!);
    final verifier = Signer('SHA-1/RSA') as RSASigner..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
    expect(verifier.verifySignature(Uint8List.fromList(utf8.encode(canonicalize(signedInfo))), RSASignature(value)), isTrue);
    // Qualquer mudança no conteúdo muda o resumo.
    infNFe.findAllElements('vNF').single.innerText = '99.99';
    expect(digestOf(infNFe), isNot(signature.findAllElements('DigestValue').single.innerText));
  });

  test('QR Code v2: online e contingência, com o hash do CSC', () async {
    final online = buildNfce(input(), testCredential());
    final params = online.qrCode.split('?p=').last.split('|');
    expect(online.qrCode, startsWith('https://www.homologacao.nfce.fazenda.sp.gov.br/qrcode?p='));
    expect(params.sublist(0, 4), [online.accessKey, '2', '2', '1']);
    final expected = SHA1Digest()
        .process(Uint8List.fromList(utf8.encode('${params.sublist(0, 4).join('|')}CSC-SO-DE-TESTE-0123456789')))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    expect(params[4], expected);

    final offline = buildNfce(input(emissionType: 9), testCredential());
    expect(await schemaErrors(offline.xml), isEmpty);
    final xml = XmlDocument.parse(offline.xml);
    expect(xml.findAllElements('tpEmis').single.innerText, '9');
    expect(offline.accessKey[34], '9');
    final p = offline.qrCode.split('?p=').last.split('|');
    final digest = xml.findAllElements('DigestValue').single.innerText;
    expect(p.sublist(1, 7), ['2', '2', '26', '30.00', utf8.encode(digest).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), '1']);
  });

  test('nota de referência para a conferência independente da API (xml-crypto)', () {
    // A API confere esta nota com outra implementação de assinatura (apps/api/src/fiscal/nfce-signature.spec.ts).
    // A nota é determinística: com UPDATE_NFCE_FIXTURE=1 o arquivo é regravado.
    final fixture = File('test/fixtures/fiscal/nfce-assinada.xml');
    final xml = buildNfce(input(cpf: '529.982.247-25'), testCredential()).xml;
    if (Platform.environment['UPDATE_NFCE_FIXTURE'] == '1' || !fixture.existsSync()) fixture.writeAsStringSync(xml);
    expect(fixture.readAsStringSync(), xml);
  });

  test('unidade do produto em uCom e uTrib; sem unidade, UN', () {
    final xml = buildNfce(input(firstUnit: 'CX'), testCredential()).xml;
    expect(RegExp('<uCom>([A-Z]+)</uCom>').allMatches(xml).map((m) => m.group(1)), ['CX', 'UN']);
    expect(RegExp('<uTrib>([A-Z]+)</uTrib>').allMatches(xml).map((m) => m.group(1)), ['CX', 'UN']);
  });

  test('o que não dá para emitir vira código do catálogo', () {
    expect(() => buildNfce(input(tax: {...simplesTax, 'icms_csosn': '201'}), testCredential()),
        throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA723')));
    const outside = NfceIssuer(
      cnpj: '11222333000181', stateRegistration: '1', legalName: 'X', tradeName: 'X', street: 'R', number: '1',
      district: 'C', cityCode: '2927408', city: 'Salvador', uf: 'BA', postalCode: '40000000', taxRegime: 1,
    );
    expect(() => buildNfce(input(issuer: outside), testCredential()), throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA725')));
    expect(() => NfceIssuer.fromFiscal({'branch': {'cnpj': '1'}, 'company': {}}),
        throwsA(isA<FiscalException>().having((e) => e.code, 'code', 'FA724')));
  });
}
