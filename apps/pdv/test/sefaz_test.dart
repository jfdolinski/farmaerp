import 'dart:async';
import 'dart:io';

import 'package:farmaerp_pdv/fiscal/nfce_credentials.dart';
import 'package:farmaerp_pdv/fiscal/sefaz.dart';
import 'package:flutter_test/flutter_test.dart';

// Respostas no formato do manual da NF-e (retEnviNFe com protNFe), montadas à mão: nenhum teste
// fala com a Sefaz de verdade.
const signedNfe = '<?xml version="1.0" encoding="UTF-8"?><NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe Id="NFe1"/></NFe>';

String response({String batch = '104', String batchReason = 'Lote processado', String status = '100', String reason = 'Autorizado o uso da NF-e', String prefix = ''}) {
  final p = prefix.isEmpty ? '' : '$prefix:';
  final ns = prefix.isEmpty ? 'xmlns="http://www.portalfiscal.inf.br/nfe"' : 'xmlns:$prefix="http://www.portalfiscal.inf.br/nfe"';
  final protocol = batch == '104'
      ? '<${p}protNFe versao="4.00"><${p}infProt><${p}tpAmb>2</${p}tpAmb><${p}chNFe>35261111222333000181650010000000011000000019</${p}chNFe>'
          '<${p}dhRecbto>2026-11-26T15:00:01-03:00</${p}dhRecbto><${p}nProt>135260000000123</${p}nProt>'
          '<${p}digVal>abc=</${p}digVal><${p}cStat>$status</${p}cStat><${p}xMotivo>$reason</${p}xMotivo></${p}infProt></${p}protNFe>'
      : '';
  return '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>'
      '<nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4">'
      '<${p}retEnviNFe $ns versao="4.00"><${p}tpAmb>2</${p}tpAmb><${p}cStat>$batch</${p}cStat><${p}xMotivo>$batchReason</${p}xMotivo>$protocol</${p}retEnviNFe>'
      '</nfeResultMsg></soap:Body></soap:Envelope>';
}

final credentials = NfceCredentials(
  credentialVersion: 'v', privateKeyPem: 'k', certificatePem: 'c', cscId: '000001', csc: 'CSC', validTo: _farFuture,
);
final _farFuture = DateTime.utc(2099);

class FakeTransport implements SefazTransport {
  FakeTransport(this.reply);

  final FutureOr<String> Function() reply;
  final calls = <(Uri, String)>[];

  @override
  Future<String> post(Uri url, String body, {required NfceCredentials credentials, required Duration timeout}) async {
    calls.add((url, body));
    return reply();
  }
}

void main() {
  test('endereços por UF e ambiente; RS e SC na SVRS; UF fora das atendidas fica sem', () {
    expect(authorizationUrl('SP', 2)?.host, 'homologacao.nfce.fazenda.sp.gov.br');
    expect(authorizationUrl('SP', 1)?.host, 'nfce.fazenda.sp.gov.br');
    expect(authorizationUrl('RS', 2), authorizationUrl('SC', 2));
    expect(authorizationUrl('BA', 2), isNull);
  });

  test('envelope: lote síncrono com a nota assinada, sem a declaração do XML', () {
    final envelope = authorizationEnvelope(signedNfe, batchId: '123');
    expect(envelope, contains('<idLote>123</idLote><indSinc>1</indSinc><NFe xmlns='));
    expect(envelope.indexOf('<?xml'), 0);
    expect('<?xml'.allMatches(envelope), hasLength(1));
    expect(envelope, contains('<nfeDadosMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4">'));
  });

  test('autorizada (100 e 150): monta o nfeProc com a nota e o protocolo como veio', () {
    for (final prefix in ['', 'nfe']) {
      final result = parseAuthorization(response(prefix: prefix), signedNfe: signedNfe) as SefazAuthorized;
      expect([result.protocol, result.statusCode], ['135260000000123', '100']);
      expect(result.authorizedAt, DateTime.utc(2026, 11, 26, 18, 0, 1));
      expect(result.procXml, startsWith('<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><NFe '));
      expect(result.procXml, contains('<protNFe versao="4.00"><infProt><tpAmb>2</tpAmb>'));
      expect(result.procXml, endsWith('</protNFe></nfeProc>'));
    }
    expect(parseAuthorization(response(status: '150', reason: 'Autorizado fora de prazo'), signedNfe: signedNfe), isA<SefazAuthorized>());
  });

  test('recusada na nota ou no lote; serviço parado e resposta estranha ficam pendentes', () {
    final rejected = parseAuthorization(response(status: '539', reason: 'Duplicidade de NF-e'), signedNfe: signedNfe) as SefazRejected;
    expect([rejected.statusCode, rejected.reason], ['539', 'Duplicidade de NF-e']);
    final batch = parseAuthorization(response(batch: '225', batchReason: 'Falha no Schema XML'), signedNfe: signedNfe) as SefazRejected;
    expect(batch.statusCode, '225');
    expect(parseAuthorization(response(batch: '108', batchReason: 'Serviço Paralisado Momentaneamente'), signedNfe: signedNfe), isA<SefazUnavailable>());
    expect(parseAuthorization('<html>erro</html>', signedNfe: signedNfe), isA<SefazUnavailable>());
    expect(parseAuthorization('não é xml', signedNfe: signedNfe), isA<SefazUnavailable>());
  });

  test('cliente: sem conexão, tempo esgotado e erro HTTP viram "sem resposta"; UF sem serviço também', () async {
    final ok = FakeTransport(() => response());
    final client = SefazClient(transport: ok);
    final result = await client.authorize(signedNfe: signedNfe, uf: 'MG', environment: 2, credentials: credentials);
    expect(result, isA<SefazAuthorized>());
    expect(ok.calls.single.$1.host, 'hnfce.fazenda.mg.gov.br');
    expect(RegExp(r'<idLote>\d{15}</idLote>').hasMatch(ok.calls.single.$2), isTrue);

    for (final failure in <Object>[
      const SocketException('sem rede'),
      TimeoutException('demorou'),
      const HttpException('Sefaz respondeu 503'),
      const HandshakeException('certificado'),
    ]) {
      final failing = SefazClient(transport: FakeTransport(() => throw failure));
      expect(await failing.authorize(signedNfe: signedNfe, uf: 'SP', environment: 2, credentials: credentials), isA<SefazUnavailable>());
    }
    final none = FakeTransport(() => response());
    expect(await SefazClient(transport: none).authorize(signedNfe: signedNfe, uf: 'BA', environment: 2, credentials: credentials),
        isA<SefazUnavailable>());
    expect(none.calls, isEmpty);
  });
}
