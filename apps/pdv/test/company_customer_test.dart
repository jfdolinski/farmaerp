import 'package:farmaerp_pdv/core/document.dart';
import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CNPJ', () {
    test('confere os dígitos, com ou sem pontuação, inclusive o alfanumérico', () {
      expect(isValidCnpj('11.222.333/0001-81'), isTrue);
      expect(isValidCnpj('11222333000181'), isTrue);
      expect(isValidCnpj('11222333000182'), isFalse);
      expect(isValidCnpj('11111111111111'), isFalse);
      expect(isValidCnpj('1122233300018'), isFalse);
      // Alfanumérico (Receita, a partir de 2026): letras valem pelo código ASCII menos 48.
      expect(isValidCnpj('12.ABC.345/01DE-35'), isTrue);
      expect(isValidCnpj('12ABC34501DE36'), isFalse);
    });
  });

  group('pessoa jurídica no caixa', () {
    test('vai para a central como empresa, limpa: só dígitos no CEP, telefone e município; UF em maiúsculas', () {
      const company = CompanyCustomer(
        cnpj: '11.222.333/0001-81', legalName: '  Empresa Fictícia Ltda ', tradeName: ' ', stateRegistration: '110042490114', ieIndicator: 1,
        email: ' compras@exemplo.test ', phone: '(11) 3333-4444', postalCode: '01001-000', street: 'Praça da Sé', streetNumber: '100',
        district: 'Sé', city: 'São Paulo', cityCode: '355030-8', state: 'sp',
      );
      expect(company.toJson(), {
        'personType': 'company', 'document': '11222333000181', 'name': 'Empresa Fictícia Ltda', 'tradeName': null,
        'stateRegistration': '110042490114', 'ieIndicator': '1', 'email': 'compras@exemplo.test', 'phone': '1133334444',
        'postalCode': '01001000', 'street': 'Praça da Sé', 'streetNumber': '100', 'complement': null, 'district': 'Sé',
        'city': 'São Paulo', 'cityCode': '3550308', 'state': 'SP',
      });
    });

    test('a consulta do CNPJ preenche o cadastro, sem inscrição nem indicador (o operador informa)', () {
      final company = CompanyCustomer.fromLookup('11222333000181', {
        'legalName': 'Empresa Fictícia Ltda', 'tradeName': 'Fictícia', 'city': 'São Paulo', 'cityCode': '3550308', 'state': 'SP',
        'postalCode': '01001000', 'street': 'Praça da Sé', 'streetNumber': '100', 'district': 'Sé', 'email': 'x@exemplo.test',
      });
      expect([company.legalName, company.tradeName, company.cityCode, company.stateRegistration, company.ieIndicator],
          ['Empresa Fictícia Ltda', 'Fictícia', '3550308', null, null]);
      expect(CompanyCustomer.fromLookup('11222333000181', const {}).legalName, '');
    });
  });
}
