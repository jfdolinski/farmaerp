import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/local_logger.dart';
import '../core/secret_store.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';

const _seedKey = 'terminal_fiscal_seed';
const _info = 'farmaerp-nfce-credentials-v1';

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> _decode(String text) => base64Url.decode(base64Url.normalize(text));

/// Texto assinado pela chave do terminal para registrar a chave de criptografia (igual à API).
String fiscalKeyMessage(String terminalId, String publicKey) => 'farmaerp-terminal-fiscal-key:$terminalId:$publicKey';

/// Texto autenticado junto com a entrega: terminal e versão do certificado e do CSC.
String envelopeContext(String terminalId, String credentialVersion) => '$_info\n$terminalId\n$credentialVersion';

class NfceCredentialException implements Exception {
  const NfceCredentialException(this.code);
  final String code;
}

/// Chave X25519 do caixa, só para receber o certificado. A privada nunca sai do aparelho.
class FiscalKey {
  FiscalKey._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;
  final String publicKey;

  static final _algorithm = X25519();

  static Future<FiscalKey> loadOrCreate(SecretStore store) async {
    final saved = await store.read(_seedKey);
    if (saved != null) return fromSeed(_decode(saved));
    final generated = await _algorithm.newKeyPair();
    final seed = await generated.extractPrivateKeyBytes();
    await store.write(_seedKey, _encode(seed));
    return fromSeed(seed);
  }

  static Future<FiscalKey> fromSeed(List<int> seed) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return FiscalKey._(keyPair, _encode(publicKey.bytes));
  }

  /// Abre a entrega da central. Chave, terminal ou versão diferentes: FA732.
  Future<List<int>> open(Map<String, dynamic> envelope, String context) async {
    try {
      if (envelope['v'] != 1) throw const NfceCredentialException('FA732');
      final ephemeral = _decode(envelope['epk'] as String);
      final data = _decode(envelope['data'] as String);
      final shared = await _algorithm.sharedSecretKey(
        keyPair: _keyPair,
        remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519),
      );
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: [...ephemeral, ..._decode(publicKey)],
        info: utf8.encode(_info),
      );
      return await AesGcm.with256bits().decrypt(
        SecretBox(
          data.sublist(0, data.length - 16),
          nonce: _decode(envelope['nonce'] as String),
          mac: Mac(data.sublist(data.length - 16)),
        ),
        secretKey: key,
        aad: utf8.encode(context),
      );
    } on NfceCredentialException {
      rethrow;
    } catch (_) {
      throw const NfceCredentialException('FA732');
    }
  }
}

/// Certificado e CSC abertos, só em memória, na hora de emitir.
class NfceCredentials {
  const NfceCredentials({
    required this.credentialVersion,
    required this.privateKeyPem,
    required this.certificatePem,
    required this.cscId,
    required this.csc,
    required this.validTo,
  });

  final String credentialVersion;
  final String privateKeyPem;
  final String certificatePem;
  final String cscId;
  final String csc;
  final DateTime validTo;

  static NfceCredentials parse(List<int> plain) {
    final json = jsonDecode(utf8.decode(plain));
    if (json is! Map<String, dynamic>) throw const NfceCredentialException('FA732');
    final values = [json['credentialVersion'], json['privateKey'], json['certificate'], json['cscId'], json['csc'], json['validTo']];
    if (values.any((value) => value is! String || value.isEmpty)) throw const NfceCredentialException('FA732');
    final validTo = DateTime.tryParse(json['validTo'] as String);
    if (validTo == null) throw const NfceCredentialException('FA732');
    return NfceCredentials(
      credentialVersion: json['credentialVersion'] as String,
      privateKeyPem: json['privateKey'] as String,
      certificatePem: json['certificate'] as String,
      cscId: json['cscId'] as String,
      csc: json['csc'] as String,
      validTo: validTo,
    );
  }
}

/// Situação da NFC-e neste caixa, para a tela.
enum NfceReadiness {
  /// A filial não emite NFC-e.
  off,

  /// Ligada, esperando o certificado chegar (primeira vez, troca ou sem internet).
  waiting,

  /// Certificado e CSC guardados e dentro da validade.
  ready,

  /// O certificado guardado venceu.
  expired,
}

/// Situação da NFC-e pelo que está no banco local.
NfceReadiness nfceReadiness(LocalDatabase database, DateTime now) {
  final settings = (database.fiscal?['nfce'] as Map?)?.cast<String, dynamic>();
  if (settings?['enabled'] != true) return NfceReadiness.off;
  final stored = database.nfceCredential;
  if (stored == null || stored.credentialVersion != settings?['credential_version']) return NfceReadiness.waiting;
  return stored.validTo.isAfter(now) ? NfceReadiness.ready : NfceReadiness.expired;
}

/// Texto da barra de situação. Null quando a filial não emite NFC-e.
String? nfceStatusText(LocalDatabase database, DateTime now) {
  final settings = (database.fiscal?['nfce'] as Map?)?.cast<String, dynamic>();
  final homologation = settings?['environment'] != 1 ? ' (homologação)' : '';
  return switch (nfceReadiness(database, now)) {
    NfceReadiness.off => null,
    NfceReadiness.waiting => 'NFC-e$homologation: aguardando o certificado',
    NfceReadiness.ready => 'NFC-e$homologation: pronta',
    NfceReadiness.expired => 'NFC-e: certificado vencido',
  };
}

/// Busca o certificado e o CSC quando a filial liga a NFC-e ou quando eles mudam, e guarda a
/// entrega ainda cifrada. Nunca derruba a sincronização: o erro fica registrado e a próxima
/// rodada tenta de novo.
class NfceCredentialService extends ChangeNotifier {
  NfceCredentialService({
    required this.api,
    required this.database,
    required this.store,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TerminalApi api;
  final LocalDatabase database;
  final SecretStore store;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  FiscalKey? _key;
  String? _lastError;

  /// Código do último erro na busca (ex.: FA943 certificado vencido na central), até dar certo.
  String? get lastError => _lastError;

  Map<String, dynamic>? get _settings => (database.fiscal?['nfce'] as Map?)?.cast<String, dynamic>();

  bool get enabled => _settings?['enabled'] == true;

  /// 1 produção, 2 homologação.
  int get environment => (_settings?['environment'] as num?)?.toInt() ?? 2;

  /// Prazo para transmitir a nota emitida sem internet.
  Duration get contingencyLimit => Duration(hours: (_settings?['contingency_hours'] as num?)?.toInt() ?? 24);

  NfceReadiness get readiness => nfceReadiness(database, _clock());

  Future<FiscalKey> _fiscalKey() async => _key ??= await FiscalKey.loadOrCreate(store);

  /// Chamado depois de cada sincronização bem-sucedida.
  Future<void> refresh({
    required String accessToken,
    required String terminalId,
    required Future<String> Function(String message) sign,
  }) async {
    if (!enabled) {
      if (database.nfceCredential != null) {
        database.clearNfceCredential();
        logger?.info('NFC-e desligada na filial: certificado removido do caixa');
        notifyListeners();
      }
      _lastError = null;
      return;
    }
    final version = _settings?['credential_version'];
    if (version is! String) return;
    final key = await _fiscalKey();
    final stored = database.nfceCredential;
    if (stored != null && stored.credentialVersion == version && stored.fiscalKey == key.publicKey) return;

    try {
      await api.registerFiscalKey(
        accessToken: accessToken,
        publicKey: key.publicKey,
        signature: await sign(fiscalKeyMessage(terminalId, key.publicKey)),
      );
      final response = await api.nfceCredentials(accessToken: accessToken);
      final deliveredVersion = response['credentialVersion'];
      final envelope = response['envelope'];
      if (deliveredVersion is! String || envelope is! Map) throw const NfceCredentialException('FA732');
      final opened = NfceCredentials.parse(
        await key.open(envelope.cast<String, dynamic>(), envelopeContext(terminalId, deliveredVersion)),
      );
      if (opened.credentialVersion != deliveredVersion) throw const NfceCredentialException('FA732');
      database.saveNfceCredential(StoredNfceCredential(
        credentialVersion: deliveredVersion,
        fiscalKey: key.publicKey,
        validTo: opened.validTo,
        envelope: envelope.cast<String, dynamic>(),
        receivedAt: _clock(),
      ));
      _lastError = null;
      logger?.info('Certificado da NFC-e recebido');
    } on NfceCredentialException catch (error) {
      _lastError = error.code;
      logger?.error('Certificado da NFC-e não abriu neste caixa', errorCode: error.code);
    } on ApiException catch (error) {
      // Sem internet: tenta na próxima rodada, sem marcar erro.
      if (error.code == 'FA001') return;
      _lastError = error.code;
      logger?.warn('Central recusou a entrega do certificado da NFC-e', fields: {'error_code': error.code});
    } finally {
      notifyListeners();
    }
  }

  /// Certificado e CSC abertos para emitir. Null se ainda não chegaram.
  Future<NfceCredentials?> credentials({required String terminalId}) async {
    final stored = database.nfceCredential;
    if (stored == null) return null;
    final key = await _fiscalKey();
    if (stored.fiscalKey != key.publicKey) return null;
    return NfceCredentials.parse(await key.open(stored.envelope, envelopeContext(terminalId, stored.credentialVersion)));
  }
}
