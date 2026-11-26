import 'dart:math';

/// Código IBGE das UFs (cUF).
const ufCodes = <String, String>{
  'RO': '11', 'AC': '12', 'AM': '13', 'RR': '14', 'PA': '15', 'AP': '16', 'TO': '17', 'MA': '21', 'PI': '22',
  'CE': '23', 'RN': '24', 'PB': '25', 'PE': '26', 'AL': '27', 'SE': '28', 'BA': '29', 'MG': '31', 'ES': '32',
  'RJ': '33', 'SP': '35', 'PR': '41', 'SC': '42', 'RS': '43', 'MS': '50', 'MT': '51', 'GO': '52', 'DF': '53',
};

/// Dígito verificador da chave (módulo 11, pesos 2 a 9 da direita para a esquerda).
int accessKeyDigit(String first43) {
  var sum = 0;
  var weight = 2;
  for (var i = first43.length - 1; i >= 0; i -= 1) {
    sum += int.parse(first43[i]) * weight;
    weight = weight == 9 ? 2 : weight + 1;
  }
  final rest = sum % 11;
  return rest < 2 ? 0 : 11 - rest;
}

/// Código numérico da nota (cNF): 8 dígitos ao acaso, diferente do número da nota.
String randomNumericCode(int number, [Random? random]) {
  final source = random ?? Random.secure();
  while (true) {
    final code = source.nextInt(100000000).toString().padLeft(8, '0');
    if (code != number.toString().padLeft(8, '0')) return code;
  }
}

/// Chave de acesso de 44 dígitos: cUF, AAMM, CNPJ, modelo, série, número, tpEmis, cNF e DV.
String accessKey({
  required String uf,
  required DateTime emittedAt,
  required String cnpj,
  required int model,
  required int series,
  required int number,
  required int emissionType,
  required String numericCode,
}) {
  final yymm = '${(emittedAt.year % 100).toString().padLeft(2, '0')}${emittedAt.month.toString().padLeft(2, '0')}';
  final first43 = '${ufCodes[uf]!}$yymm$cnpj${model.toString().padLeft(2, '0')}${series.toString().padLeft(3, '0')}'
      '${number.toString().padLeft(9, '0')}$emissionType$numericCode';
  if (first43.length != 43) throw ArgumentError('Dados da chave fora do tamanho.');
  return '$first43${accessKeyDigit(first43)}';
}
