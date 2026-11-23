/// Dinheiro no caixa sempre em centavos (inteiro). Estas funções só formatam e leem o que se digita.
library;

/// R$ 1.234,56
String formatCents(int cents) {
  final negative = cents < 0;
  final value = cents.abs();
  final reais = (value ~/ 100).toString();
  final buffer = StringBuffer();
  for (var i = 0; i < reais.length; i += 1) {
    if (i > 0 && (reais.length - i) % 3 == 0) buffer.write('.');
    buffer.write(reais[i]);
  }
  return '${negative ? '-' : ''}R\$ ${buffer.toString()},${(value % 100).toString().padLeft(2, '0')}';
}

/// Lê "12,90", "12.90", "1.234,56" ou "R$ 5" em centavos. Vazio ou inválido: null.
int? parseCents(String text) {
  var clean = text.replaceAll(RegExp(r'[R$\s]'), '');
  if (clean.isEmpty) return null;
  if (clean.contains(',')) {
    clean = clean.replaceAll('.', '').replaceAll(',', '.');
  }
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(clean)) return null;
  final parts = clean.split('.');
  final reais = int.parse(parts[0]);
  final centavos = parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0;
  return reais * 100 + centavos;
}

/// Quantidade em milésimos: 1, 2,5 ou 0,25.
int? parseMilli(String text) {
  final clean = text.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,7}(\.\d{1,3})?$').hasMatch(clean)) return null;
  final parts = clean.split('.');
  final whole = int.parse(parts[0]);
  final fraction = parts.length > 1 ? int.parse(parts[1].padRight(3, '0')) : 0;
  final value = whole * 1000 + fraction;
  return value > 0 ? value : null;
}

/// 1, 2,5 ou 0,250 → texto curto para a tela.
String formatMilli(int milli) {
  if (milli % 1000 == 0) return (milli ~/ 1000).toString();
  final text = (milli / 1000).toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '');
  return text.replaceAll('.', ',');
}

/// Preço × quantidade, arredondado como a central (meio centavo para cima).
int lineGrossCents(int unitPriceCents, int quantityMilli) =>
    ((unitPriceCents * quantityMilli) / 1000).round();
