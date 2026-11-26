import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Chaves públicas que assinam as versões (cópia de scripts/release/update-keys.json, conferida
/// por teste). Pode ser trocada na compilação: `--dart-define=UPDATE_PUBLIC_KEYS=chave1,chave2`.
const updatePublicKeysDefine = String.fromEnvironment('UPDATE_PUBLIC_KEYS');
const builtInUpdatePublicKeys = <String>['Ysd70sEK+5+9mtWwd4Iv7Q8o7NEl+sR6sds2ijlsg1U='];

List<String> configuredUpdateKeys() => updatePublicKeysDefine.isEmpty
    ? builtInUpdatePublicKeys
    : updatePublicKeysDefine.split(',').map((key) => key.trim()).where((key) => key.isNotEmpty).toList();

/// Dados da versão que a assinatura cobre.
class ReleaseManifest {
  const ReleaseManifest({
    required this.app,
    required this.platform,
    required this.version,
    required this.sha256,
    required this.size,
  });

  final String app;
  final String platform;
  final String version;
  final String sha256;
  final int size;

  /// O mesmo texto da API e de scripts/release/release-format.mjs.
  List<int> message() => utf8.encode('farmaerp-release-v1\n$app\n$platform\n$version\n$sha256\n$size');
}

/// Confere a assinatura Ed25519 com qualquer uma das chaves aceitas.
Future<bool> verifyReleaseSignature(ReleaseManifest manifest, String signature, List<String> publicKeys) async {
  final List<int> signatureBytes;
  try {
    signatureBytes = base64.decode(signature);
  } on FormatException {
    return false;
  }
  if (signatureBytes.length != 64) return false;
  final algorithm = Ed25519();
  for (final raw in publicKeys) {
    final List<int> keyBytes;
    try {
      keyBytes = base64.decode(raw);
    } on FormatException {
      continue;
    }
    if (keyBytes.length != 32) continue;
    final ok = await algorithm.verify(
      manifest.message(),
      signature: Signature(signatureBytes, publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519)),
    );
    if (ok) return true;
  }
  return false;
}
