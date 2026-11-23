import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Confere o PIN contra o hash que veio da central: pbkdf2-sha256$rodadas$sal$hash (base64).
/// Formato desconhecido nunca confere.
Future<bool> verifyPin(String pin, String hash) async {
  final parts = hash.split(r'$');
  if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
  final iterations = int.tryParse(parts[1]);
  if (iterations == null || iterations < 100000 || iterations > 5000000) return false;
  final List<int> salt;
  final List<int> expected;
  try {
    salt = base64.decode(parts[2]);
    expected = base64.decode(parts[3]);
  } on FormatException {
    return false;
  }
  final algorithm = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: expected.length * 8);
  final key = await algorithm.deriveKeyFromPassword(password: pin, nonce: salt);
  final actual = await key.extractBytes();
  if (actual.length != expected.length) return false;
  // Comparação em tempo constante.
  var difference = 0;
  for (var i = 0; i < actual.length; i += 1) {
    difference |= actual[i] ^ expected[i];
  }
  return difference == 0;
}
