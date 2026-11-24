/// Texto para busca: minúsculas, sem acento e só letras e números (o resto vira espaço).
/// "Dipirona Sódica 500 mg" → "dipirona sodica 500 mg".
String foldText(String? value) {
  if (value == null || value.isEmpty) return '';
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final plain = _accents[char] ?? char;
    buffer.write(RegExp(r'[a-z0-9]').hasMatch(plain) ? plain : ' ');
  }
  return buffer.toString().replaceAll(RegExp(r' +'), ' ').trim();
}

const _accents = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y',
};
