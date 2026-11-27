/// CPF com os dígitos verificadores certos (pontuação é ignorada). Igual a app.is_valid_cpf na central.
bool isValidCpf(String value) {
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length != 11 || RegExp(r'^(\d)\1{10}$').hasMatch(digits)) return false;
  final numbers = [for (final char in digits.split('')) int.parse(char)];
  for (final size in [9, 10]) {
    var sum = 0;
    for (var index = 0; index < size; index += 1) {
      sum += numbers[index] * (size + 1 - index);
    }
    final rest = (sum * 10) % 11;
    if ((rest == 10 ? 0 : rest) != numbers[size]) return false;
  }
  return true;
}

/// CNPJ com os dígitos verificadores certos, inclusive o alfanumérico (pontuação é ignorada).
/// Igual a app.is_valid_cnpj na central.
bool isValidCnpj(String value) {
  final cnpj = value.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-Z]{12}[0-9]{2}$').hasMatch(cnpj) || RegExp(r'^(.)\1{13}$').hasMatch(cnpj)) return false;
  int digit(String base) {
    final weights = base.length == 12 ? const [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : const [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    var total = 0;
    for (var index = 0; index < base.length; index += 1) {
      total += (base.codeUnitAt(index) - 48) * weights[index];
    }
    final rest = total % 11;
    return rest < 2 ? 0 : 11 - rest;
  }

  final first = digit(cnpj.substring(0, 12));
  final second = digit('${cnpj.substring(0, 12)}$first');
  return cnpj.endsWith('$first$second');
}
