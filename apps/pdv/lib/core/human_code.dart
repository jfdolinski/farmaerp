const _saleCounterWidth = 6;

/// Código da venda para tela e cupom, como `2-000123`: número do terminal + contador.
/// Não depende da central, então funciona offline. Não substitui o número fiscal.
String formatSaleCode({required int terminalNumber, required int counter}) {
  if (terminalNumber < 1 || counter < 1) {
    throw ArgumentError('O terminal e o contador começam em 1.');
  }
  final padded = counter.toString().padLeft(_saleCounterWidth, '0');
  return '$terminalNumber-$padded';
}
