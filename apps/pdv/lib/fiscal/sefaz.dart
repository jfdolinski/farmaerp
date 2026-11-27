import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

import 'nfce_credentials.dart';

const _nfeNamespace = 'http://www.portalfiscal.inf.br/nfe';
const _wsdlNamespace = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4';

/// Serviço de autorização da NFC-e (NFeAutorizacao4) por UF. RS e SC usam a SVRS.
///
/// CONFERIR com o portal de cada UF antes de produção (endereços do manual de cada Sefaz).
const _authorization = <String, (String homologation, String production)>{
  'SP': ('https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeAutorizacao4.asmx', 'https://nfce.fazenda.sp.gov.br/ws/NFeAutorizacao4.asmx'),
  'PR': ('https://homologacao.nfce.sefa.pr.gov.br/nfce/NFeAutorizacao4', 'https://nfce.sefa.pr.gov.br/nfce/NFeAutorizacao4'),
  'RS': (
    'https://nfce-homologacao.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
    'https://nfce.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
  ),
  'SC': (
    'https://nfce-homologacao.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
    'https://nfce.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
  ),
  'MG': ('https://hnfce.fazenda.mg.gov.br/nfce/services/NFeAutorizacao4', 'https://nfce.fazenda.mg.gov.br/nfce/services/NFeAutorizacao4'),
};

/// Serviço de autorização da NF-e modelo 55 (NFeAutorizacao4) por UF: outros endereços, o mesmo
/// envelope. SC usa a SVRS. Os mesmos da central (nfe-sefaz.ts).
///
/// CONFERIR com o portal de cada UF antes de produção.
const _nfeAuthorization = <String, (String homologation, String production)>{
  'SP': ('https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx', 'https://nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx'),
  'PR': ('https://homologacao.nfe.sefa.pr.gov.br/nfe/NFeAutorizacao4', 'https://nfe.sefa.pr.gov.br/nfe/NFeAutorizacao4'),
  'MG': ('https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4', 'https://nfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4'),
  'RS': (
    'https://nfe-homologacao.sefazrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
    'https://nfe.sefazrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
  ),
  'SC': (
    'https://nfe-homologacao.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
    'https://nfe.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
  ),
};

/// Endereço da autorização na UF, no ambiente (1 produção, 2 homologação) e no modelo (65 NFC-e,
/// 55 NF-e). Null se não atendida.
Uri? authorizationUrl(String uf, int environment, {String model = '65'}) {
  final urls = (model == '55' ? _nfeAuthorization : _authorization)[uf];
  if (urls == null) return null;
  return Uri.parse(environment == 1 ? urls.$2 : urls.$1);
}

/// Resposta da Sefaz para uma NFC-e.
sealed class SefazResult {
  const SefazResult();
}

/// Autorizada: o XML final (nfeProc) junta a nota assinada e o protocolo.
class SefazAuthorized extends SefazResult {
  const SefazAuthorized({
    required this.protocol,
    required this.statusCode,
    required this.reason,
    required this.authorizedAt,
    required this.procXml,
  });

  final String protocol;
  final String statusCode;
  final String reason;
  final DateTime authorizedAt;
  final String procXml;
}

/// Recusada (rejeição ou denegação): a nota não vale; o código e o motivo vão para a retaguarda.
class SefazRejected extends SefazResult {
  const SefazRejected({required this.statusCode, required this.reason});

  final String statusCode;
  final String reason;
}

/// Sem resposta útil (sem internet, tempo esgotado, serviço parado): a nota fica pendente.
/// [sent] diz se o pedido pode ter chegado à Sefaz: sem conexão (ou sem endereço), não chegou; com o
/// tempo esgotado depois de enviar, pode ter chegado (é preciso consultar antes de enviar de novo).
class SefazUnavailable extends SefazResult {
  const SefazUnavailable(this.reason, {this.sent = true});

  final String reason;
  final bool sent;
}

/// A mesma nota já está na Sefaz (204): a resposta da primeira vez se perdeu. Consultar.
class SefazDuplicate extends SefazResult {
  const SefazDuplicate({required this.statusCode, required this.reason});

  final String statusCode;
  final String reason;
}

/// A consulta mostra a nota cancelada (pela retaguarda ou pela central).
class SefazCanceled extends SefazResult {
  const SefazCanceled({required this.statusCode, required this.reason});

  final String statusCode;
  final String reason;
}

/// A consulta diz que a Sefaz não tem a nota (217): pode enviar.
class SefazNotFound extends SefazResult {
  const SefazNotFound();
}

/// Consulta da NFC-e pela chave (NFeConsultaProtocolo4) por UF. RS e SC usam a SVRS.
///
/// CONFERIR com o portal de cada UF antes de produção (os mesmos da central, em nfce-sefaz.ts).
const _consult = <String, (String homologation, String production)>{
  'SP': ('https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx', 'https://nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx'),
  'PR': ('https://homologacao.nfce.sefa.pr.gov.br/nfce/NFeConsultaProtocolo4', 'https://nfce.sefa.pr.gov.br/nfce/NFeConsultaProtocolo4'),
  'RS': ('https://nfce-homologacao.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx', 'https://nfce.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx'),
  'SC': ('https://nfce-homologacao.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx', 'https://nfce.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx'),
  'MG': ('https://hnfce.fazenda.mg.gov.br/nfce/services/NFeConsultaProtocolo4', 'https://nfce.fazenda.mg.gov.br/nfce/services/NFeConsultaProtocolo4'),
};

/// Consulta da NF-e modelo 55 (NFeConsultaProtocolo4) por UF. SC usa a SVRS.
///
/// CONFERIR com o portal de cada UF antes de produção.
const _nfeConsult = <String, (String homologation, String production)>{
  'SP': ('https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeconsultaprotocolo4.asmx', 'https://nfe.fazenda.sp.gov.br/ws/nfeconsultaprotocolo4.asmx'),
  'PR': ('https://homologacao.nfe.sefa.pr.gov.br/nfe/NFeConsultaProtocolo4', 'https://nfe.sefa.pr.gov.br/nfe/NFeConsultaProtocolo4'),
  'MG': ('https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeConsultaProtocolo4', 'https://nfe.fazenda.mg.gov.br/nfe2/services/NFeConsultaProtocolo4'),
  'RS': ('https://nfe-homologacao.sefazrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx', 'https://nfe.sefazrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx'),
  'SC': ('https://nfe-homologacao.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx', 'https://nfe.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx'),
};

/// Endereço da consulta na UF, no ambiente e no modelo. Null se não atendida.
Uri? consultUrl(String uf, int environment, {String model = '65'}) {
  final urls = (model == '55' ? _nfeConsult : _consult)[uf];
  if (urls == null) return null;
  return Uri.parse(environment == 1 ? urls.$2 : urls.$1);
}

/// Pedido de consulta da situação da nota pela chave.
String consultEnvelope(String accessKey, {required int environment}) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<soap12:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap12="http://www.w3.org/2003/05/soap-envelope">'
    '<soap12:Body><nfeDadosMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeConsultaProtocolo4">'
    '<consSitNFe xmlns="$_nfeNamespace" versao="4.00"><tpAmb>$environment</tpAmb><xServ>CONSULTAR</xServ>'
    '<chNFe>$accessKey</chNFe></consSitNFe></nfeDadosMsg></soap12:Body></soap12:Envelope>';

/// Lê a consulta: 100/150 autorizada (junta a nota assinada e o protocolo no nfeProc); 101/151/155
/// cancelada; 217 não consta; 108/109 parada; o resto fica como indisponível (tenta depois).
SefazResult parseConsult(String response, {required String signedNfe}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(response);
  } on XmlException {
    return const SefazUnavailable('Resposta da Sefaz fora do formato.');
  }
  final result = _first(document, 'retConsSitNFe');
  if (result == null) return const SefazUnavailable('Resposta da Sefaz sem o retorno da consulta.');
  final status = _text(result, 'cStat');
  final reason = _first(result, 'xMotivo')?.innerText.trim() ?? '';
  if (status == '217') return const SefazNotFound();
  if (status == '101' || status == '151' || status == '155') return SefazCanceled(statusCode: status, reason: reason);
  if (status != '100' && status != '150') return SefazUnavailable('Sefaz: $status $reason');
  final protocol = _first(result, 'infProt');
  final protNfe = _cut(response, 'protNFe');
  if (protocol == null || protNfe == null) return const SefazUnavailable('Consulta sem o protocolo.');
  final nfe = signedNfe.replaceFirst(RegExp(r'^<\?xml[^>]*\?>\s*'), '');
  return SefazAuthorized(
    protocol: _text(protocol, 'nProt'),
    statusCode: status,
    reason: reason,
    authorizedAt: DateTime.tryParse(_text(protocol, 'dhRecbto')) ?? DateTime.now(),
    procXml: '<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="$_nfeNamespace" versao="4.00">$nfe$protNfe</nfeProc>',
  );
}

/// Recorta o elemento da resposta como veio (a Sefaz pode assiná-lo), sem prefixo de namespace.
String? _cut(String response, String name) {
  final start = response.indexOf(RegExp('<(\\w+:)?$name[\\s>]'));
  if (start < 0) return null;
  final end = RegExp('</(\\w+:)?$name>').firstMatch(response.substring(start));
  if (end == null) return null;
  return response.substring(start, start + end.end).replaceAllMapped(RegExp(r'(</?)\w+:'), (match) => match[1]!);
}

/// O pedido não chegou a sair: sem conexão, sem resposta ao conectar ou falha no TLS. Diferente do
/// tempo esgotado depois de enviar, quando a Sefaz pode ter recebido a nota.
class SefazNotReached implements Exception {
  const SefazNotReached(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Leva o envelope até a Sefaz com o certificado do caixa no TLS. Separado para os testes. Falha
/// antes de enviar o pedido vira [SefazNotReached].
abstract class SefazTransport {
  Future<String> post(Uri url, String body, {required NfceCredentials credentials, required Duration timeout});
}

class HttpSefazTransport implements SefazTransport {
  @override
  Future<String> post(Uri url, String body, {required NfceCredentials credentials, required Duration timeout}) async {
    final context = SecurityContext(withTrustedRoots: true)
      ..useCertificateChainBytes(utf8.encode(credentials.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(credentials.privateKeyPem));
    final client = HttpClient(context: context)..connectionTimeout = timeout;
    try {
      final HttpClientRequest request;
      try {
        request = await client.postUrl(url).timeout(timeout);
      } on TimeoutException {
        throw const SefazNotReached('A Sefaz não respondeu ao conectar.');
      } on SocketException catch (error) {
        throw SefazNotReached('Sem conexão com a Sefaz: ${error.message}');
      } on HandshakeException catch (error) {
        throw SefazNotReached('Falha no TLS com a Sefaz: ${error.message}');
      }
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/soap+xml; charset=utf-8');
      request.add(utf8.encode(body));
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) throw HttpException('Sefaz respondeu ${response.statusCode}', uri: url);
      return text;
    } finally {
      client.close(force: true);
    }
  }
}

/// Lote de uma nota, síncrono (indSinc 1): a resposta já traz o protocolo.
String authorizationEnvelope(String signedNfe, {required String batchId}) {
  final nfe = signedNfe.replaceFirst(RegExp(r'^<\?xml[^>]*\?>\s*'), '');
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<soap12:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap12="http://www.w3.org/2003/05/soap-envelope">'
      '<soap12:Body><nfeDadosMsg xmlns="$_wsdlNamespace">'
      '<enviNFe xmlns="$_nfeNamespace" versao="4.00"><idLote>$batchId</idLote><indSinc>1</indSinc>$nfe</enviNFe>'
      '</nfeDadosMsg></soap12:Body></soap12:Envelope>';
}

XmlElement? _first(XmlNode node, String localName) =>
    node.descendants.whereType<XmlElement>().where((element) => element.name.local == localName).firstOrNull;

String _text(XmlNode? node, String localName) => (node == null ? null : _first(node, localName))?.innerText.trim() ?? '';

/// Lê a resposta da autorização. Lote recebido e processado (104) traz o protocolo da nota:
/// 100 e 150 autorizam; o resto recusa. Serviço parado (108, 109) conta como indisponível.
SefazResult parseAuthorization(String response, {required String signedNfe}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(response);
  } on XmlException {
    return const SefazUnavailable('Resposta da Sefaz fora do formato.');
  }
  final batch = _first(document, 'retEnviNFe');
  if (batch == null) return const SefazUnavailable('Resposta da Sefaz sem o retorno do lote.');
  final batchStatus = _text(batch, 'cStat');
  final batchReason = _first(batch, 'xMotivo')?.innerText.trim() ?? '';
  if (batchStatus == '108' || batchStatus == '109') return SefazUnavailable('Sefaz: $batchReason');
  if (batchStatus != '104') return SefazRejected(statusCode: batchStatus, reason: batchReason);
  final protocol = _first(batch, 'infProt');
  final status = _text(protocol, 'cStat');
  final reason = _text(protocol, 'xMotivo');
  // 204: a mesma nota já chegou antes (a resposta se perdeu); consultar pega o protocolo. O 539
  // (mesmo número, outra chave) é recusa de verdade.
  if (status == '204') return SefazDuplicate(statusCode: status, reason: reason);
  if (status != '100' && status != '150') return SefazRejected(statusCode: status, reason: reason);
  // O protocolo vai como veio (a Sefaz pode assiná-lo): recorte do texto, sem remontar o XML.
  final start = response.indexOf(RegExp(r'<(\w+:)?protNFe[\s>]'));
  final endMatch = RegExp(r'</(\w+:)?protNFe>').firstMatch(response.substring(max(start, 0)));
  if (start < 0 || endMatch == null) return const SefazUnavailable('Resposta da Sefaz sem o protocolo.');
  // Sem o prefixo de namespace que algumas Sefaz usam: no nfeProc o namespace padrão é o mesmo.
  final protNfe = response
      .substring(start, start + endMatch.end)
      .replaceAllMapped(RegExp(r'(</?)\w+:'), (match) => match[1]!);
  final nfe = signedNfe.replaceFirst(RegExp(r'^<\?xml[^>]*\?>\s*'), '');
  return SefazAuthorized(
    protocol: _text(protocol, 'nProt'),
    statusCode: status,
    reason: reason,
    authorizedAt: DateTime.tryParse(_text(protocol, 'dhRecbto')) ?? DateTime.now(),
    procXml: '<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="$_nfeNamespace" versao="4.00">$nfe$protNfe</nfeProc>',
  );
}

/// Envio da NFC-e à Sefaz da UF.
class SefazClient {
  SefazClient({SefazTransport? transport, this.timeout = const Duration(seconds: 15), Random? random})
    : _transport = transport ?? HttpSefazTransport(),
      _random = random ?? Random.secure();

  final SefazTransport _transport;
  final Duration timeout;
  final Random _random;

  Future<SefazResult> authorize({
    required String signedNfe,
    required String uf,
    required int environment,
    required NfceCredentials credentials,
    String model = '65',
  }) async {
    final url = authorizationUrl(uf, environment, model: model);
    if (url == null) return SefazUnavailable('UF $uf sem serviço de autorização configurado.', sent: false);
    final batchId = List.generate(15, (_) => _random.nextInt(10)).join();
    try {
      final response = await _transport.post(
        url,
        authorizationEnvelope(signedNfe, batchId: batchId),
        credentials: credentials,
        timeout: timeout,
      );
      return parseAuthorization(response, signedNfe: signedNfe);
    } on SefazNotReached catch (error) {
      return SefazUnavailable(error.message, sent: false);
    } on TimeoutException {
      return const SefazUnavailable('A Sefaz não respondeu a tempo.');
    } on SocketException catch (error) {
      return SefazUnavailable('Sem conexão com a Sefaz: ${error.message}');
    } on HandshakeException catch (error) {
      return SefazUnavailable('Falha no TLS com a Sefaz: ${error.message}', sent: false);
    } on HttpException catch (error) {
      return SefazUnavailable(error.message);
    }
  }

  /// Situação da nota pela chave. Autorizada volta com o nfeProc (a nota assinada e o protocolo).
  Future<SefazResult> consult({
    required String accessKey,
    required String signedNfe,
    required String uf,
    required int environment,
    required NfceCredentials credentials,
    String model = '65',
  }) async {
    final url = consultUrl(uf, environment, model: model);
    if (url == null) return SefazUnavailable('UF $uf sem serviço de consulta configurado.', sent: false);
    try {
      final response = await _transport.post(url, consultEnvelope(accessKey, environment: environment), credentials: credentials, timeout: timeout);
      return parseConsult(response, signedNfe: signedNfe);
    } on SefazNotReached catch (error) {
      return SefazUnavailable(error.message, sent: false);
    } on TimeoutException {
      return const SefazUnavailable('A Sefaz não respondeu a tempo.');
    } on SocketException catch (error) {
      return SefazUnavailable('Sem conexão com a Sefaz: ${error.message}');
    } on HandshakeException catch (error) {
      return SefazUnavailable('Falha no TLS com a Sefaz: ${error.message}', sent: false);
    } on HttpException catch (error) {
      return SefazUnavailable(error.message);
    }
  }
}
