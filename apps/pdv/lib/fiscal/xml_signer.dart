import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

import 'xml_c14n.dart';

/// Chave privada RSA e certificado (DER) que assinam a nota. Vêm da central já extraídos do .pfx.
class SigningCredential {
  SigningCredential({required this.privateKey, required this.certificateDer});

  /// Chave em PEM PKCS#8 ("BEGIN PRIVATE KEY") e certificado em PEM.
  factory SigningCredential.fromPem({required String privateKeyPem, required String certificatePem}) =>
      SigningCredential(privateKey: _rsaFromPkcs8(_pemBody(privateKeyPem)), certificateDer: _pemBody(certificatePem));

  final RSAPrivateKey privateKey;
  final Uint8List certificateDer;
}

Uint8List _pemBody(String pem) {
  // Junta as linhas sem os cabeçalhos; aceita quebra de linha do Windows.
  final body = pem.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => !line.startsWith('-----')).join();
  return base64.decode(body);
}

RSAPrivateKey _rsaFromPkcs8(Uint8List der) {
  final info = ASN1Parser(der).nextObject() as ASN1Sequence;
  final octets = info.elements![2] as ASN1OctetString;
  final rsa = ASN1Parser(octets.valueBytes!).nextObject() as ASN1Sequence;
  BigInt at(int index) => (rsa.elements![index] as ASN1Integer).integer!;
  return RSAPrivateKey(at(1), at(3), at(4), at(5));
}

const _dsig = 'http://www.w3.org/2000/09/xmldsig#';
const _c14n = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315';

/// Resumo (SHA-1, base64) do elemento canonicalizado.
String digestOf(XmlElement element) =>
    base64.encode(SHA1Digest().process(Uint8List.fromList(utf8.encode(canonicalize(element)))));

/// Assinatura XMLDSig envelopada (RSA-SHA1, C14N), no padrão da NF-e: o elemento assinado é
/// [signed] (com Id) e a assinatura entra no fim de [parent].
void signEnveloped({required XmlElement parent, required XmlElement signed, required SigningCredential credential}) {
  final id = signed.getAttribute('Id')!;
  final digest = digestOf(signed);
  final signedInfo = XmlDocument.parse(
    '<SignedInfo xmlns="$_dsig">'
    '<CanonicalizationMethod Algorithm="$_c14n"/>'
    '<SignatureMethod Algorithm="${_dsig}rsa-sha1"/>'
    '<Reference URI="#$id"><Transforms>'
    '<Transform Algorithm="${_dsig}enveloped-signature"/><Transform Algorithm="$_c14n"/>'
    '</Transforms><DigestMethod Algorithm="${_dsig}sha1"/><DigestValue>$digest</DigestValue></Reference>'
    '</SignedInfo>',
  ).rootElement;
  final signer = Signer('SHA-1/RSA') as RSASigner
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(credential.privateKey));
  final value = signer.generateSignature(Uint8List.fromList(utf8.encode(canonicalize(signedInfo)))).bytes;
  // Dentro de Signature, SignedInfo herda o namespace: não repete o xmlns.
  signedInfo.removeAttribute('xmlns');
  final signature = XmlElement(XmlName.parts('Signature'), [XmlAttribute(XmlName.parts('xmlns'), _dsig)], [
    signedInfo.copy(),
    XmlElement(XmlName.parts('SignatureValue'), [], [XmlText(base64.encode(value))]),
    XmlElement(XmlName.parts('KeyInfo'), [], [
      XmlElement(XmlName.parts('X509Data'), [], [
        XmlElement(XmlName.parts('X509Certificate'), [], [XmlText(base64.encode(credential.certificateDer))]),
      ]),
    ]),
  ]);
  parent.children.add(signature);
}
