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
