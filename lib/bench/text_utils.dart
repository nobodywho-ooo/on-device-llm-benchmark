const _diacritics = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ě': 'e', 'ē': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u',
  'ý': 'y', 'ñ': 'n', 'ç': 'c', 'č': 'c', 'ř': 'r', 'š': 's', 'ž': 'z',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Lowercase, strip diacritics, join thousands separators, punctuation → space.
String normalize(String s) {
  var out = s.toLowerCase();
  final sb = StringBuffer();
  for (final ch in out.split('')) {
    sb.write(_diacritics[ch] ?? ch);
  }
  out = sb.toString();
  out = out.replaceAllMapped(RegExp(r'(\d)[,  ](\d{3})'), (m) => '${m[1]}${m[2]}');
  out = out.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return out.trim();
}

/// True if any accepted alias appears as a whole-word sequence in [answer].
bool matchesAny(String answer, List<String> aliases) {
  final a = ' ${normalize(answer)} ';
  for (final alias in aliases) {
    final n = normalize(alias);
    if (n.isEmpty) continue;
    if (a.contains(' $n ')) return true;
  }
  return false;
}

final _thinkBlock = RegExp(r'<think>[\s\S]*?(</think>|$)');

/// Removes `<think>...</think>` reasoning blocks from a model response.
String stripThinking(String s) => s.replaceAll(_thinkBlock, '').trim();

double median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

String fmt(double? v, [int digits = 1]) =>
    v == null || v.isNaN || v.isInfinite ? '–' : v.toStringAsFixed(digits);
