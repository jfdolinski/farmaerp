import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../core/secret_store.dart';

const _seedKey = 'terminal_private_seed';

String _encode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _decode(String text) => base64Url.decode(base64Url.normalize(text));

/// Par de chaves Ed25519 do aparelho. A chave privada nunca sai do aparelho.
class TerminalIdentity {
  TerminalIdentity._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;

  /// Chave pública em base64url, no formato esperado pela API.
  final String publicKey;

  static final _algorithm = Ed25519();

  static Future<TerminalIdentity> loadOrCreate(SecretStore store) async {
    final saved = await store.read(_seedKey);
    if (saved != null) {
      return fromSeed(_decode(saved));
    }
    final generated = await _algorithm.newKeyPair();
    final seed = await generated.extractPrivateKeyBytes();
    await store.write(_seedKey, _encode(seed));
    return fromSeed(seed);
  }

  static Future<TerminalIdentity> fromSeed(List<int> seed) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return TerminalIdentity._(keyPair, _encode(publicKey.bytes));
  }

  static Future<void> erase(SecretStore store) => store.delete(_seedKey);

  /// Assinatura em base64url.
  Future<String> sign(String message) async {
    final signature = await _algorithm.sign(
      utf8.encode(message),
      keyPair: _keyPair,
    );
    return _encode(signature.bytes);
  }
}
