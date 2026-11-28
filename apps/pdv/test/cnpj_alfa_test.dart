import 'dart:convert';

import 'package:farmaerp_pdv/core/document.dart';
import 'package:farmaerp_pdv/fiscal/access_key.dart';
import 'package:farmaerp_pdv/fiscal/danfe_a4.dart';
import 'package:farmaerp_pdv/fiscal/nfce.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'nfce_test.dart' show issuerSimples, testCredential;
import 'nfe_test.dart' show company, devolution, sale;

// CNPJ alfanumérico (NT Conjunta DFe 2025.001 e NT 2026.004): o CNPJ tem letras nas 12 primeiras
// posições, a chave de acesso também, e o dígito vale o código ASCII menos 48 (A = 17).

/// O exemplo da Receita: 12.ABC.345/01DE-35.
const alfaCnpj = '12ABC34501DE35';

/// Conferida contra app.is_valid_access_key da central: termina em 8.
const alfaKey = '35261112ABC34501DE35550010000001231123456788';

void main() {
  test('o CNPJ de exemplo é válido com e sem a pontuação', () {
    expect(isValidCnpj(alfaCnpj), isTrue);
    expect(isValidCnpj('12.ABC.345/01DE-35'), isTrue);
    expect(isValidCnpj('12ABC34501DE36'), isFalse);
  });

  test('dígito da chave: letras valem ASCII − 48; a chave numérica continua igual', () {
    expect(accessKeyDigit(alfaKey.substring(0, 43)), 8);
    // Chave só com números (a de compra dos testes): o mesmo dígito de antes.
    expect(accessKeyDigit('4126114455566600019955001000001234100001234'), 5);
    expect(() => accessKeyDigit('3526111' '#' * 36), throwsArgumentError);
  });

  test('emitente com CNPJ alfanumérico: a chave leva as letras e o dígito certo; destinatário e nota referenciada também', () async {
    final base = sale(recipient: NfeRecipient(
      cnpj: '12.abc.345/01de-35', name: company.name, ieIndicator: 1, stateRegistration: company.stateRegistration,
      street: company.street, number: company.number, district: company.district, cityCode: company.cityCode, city: company.city,
      uf: company.uf, postalCode: company.postalCode,
    ));
    final input = NfeInput(
      issuer: NfceIssuer(
        cnpj: alfaCnpj, stateRegistration: issuerSimples.stateRegistration, legalName: issuerSimples.legalName,
        tradeName: issuerSimples.tradeName, street: issuerSimples.street, number: issuerSimples.number, district: issuerSimples.district,
        cityCode: issuerSimples.cityCode, city: issuerSimples.city, uf: issuerSimples.uf, postalCode: issuerSimples.postalCode,
        taxRegime: 3,
      ),
      recipient: base.recipient,
      items: base.items,
      payments: base.payments,
      series: base.series,
      number: base.number,
      emittedAt: base.emittedAt,
      environment: base.environment,
      numericCode: base.numericCode,
      appVersion: base.appVersion,
      operation: base.operation,
    );
    final nfe = buildNfe(input, testCredential());
    expect(nfe.accessKey.substring(6, 20), alfaCnpj);
    expect(nfe.accessKey, matches(RegExp(r'^\d{6}[0-9A-Z]{12}\d{26}$')));
    expect(accessKeyDigit(nfe.accessKey.substring(0, 43)).toString(), nfe.accessKey.substring(43));
    final doc = XmlDocument.parse(nfe.xml);
    expect(doc.findAllElements('emit').single.getElement('CNPJ')!.innerText, alfaCnpj);
    // O CNPJ do destinatário perde a pontuação, não as letras (e fica em maiúsculas).
    expect(doc.findAllElements('dest').single.getElement('CNPJ')!.innerText, alfaCnpj);
    expect(doc.findAllElements('infNFe').single.getAttribute('Id'), 'NFe${nfe.accessKey}');

    // Devolução de compra de fornecedor com CNPJ alfanumérico: a chave referenciada aceita letras.
    final devolutionNfe = buildNfe(devolution(references: const [alfaKey]), testCredential());
    expect(XmlDocument.parse(devolutionNfe.xml).findAllElements('refNFe').single.innerText, alfaKey);

    // DANFE A4: o código de barras da chave com letras também sai.
    final pdf = await buildDanfeA4(nfe.xml);
    expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
  });

  test('chave referenciada fora do formato continua recusada', () {
    for (final reference in ['1226ABC1112223330001815500100000123410000123', '3526111122233300018155001000001234100001234a', '123']) {
      expect(() => buildNfe(devolution(references: [reference]), testCredential()), throwsA(isA<FiscalException>()), reason: reference);
    }
  });
}
