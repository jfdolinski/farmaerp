import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';
import { join } from 'node:path';
import { SignedXml } from 'xml-crypto';
import { describe, expect, it } from 'vitest';

// Conferência independente da assinatura feita pelo motor fiscal do PDV (Dart): a nota de referência
// é gerada pelo teste do PDV (apps/pdv/test/nfce_test.dart) com um certificado só de teste.
const fixture = join(import.meta.dirname, '..', '..', '..', 'pdv', 'test', 'fixtures', 'fiscal', 'nfce-assinada.xml');

function signatureOf(xml: string) {
  const start = xml.indexOf('<Signature ');
  const certificate = /<X509Certificate>([^<]+)<\/X509Certificate>/.exec(xml)?.[1] ?? '';
  const verifier = new SignedXml({ publicCert: new X509Certificate(Buffer.from(certificate, 'base64')).toString() });
  verifier.loadSignature(xml.slice(start, xml.indexOf('</Signature>') + '</Signature>'.length));
  return verifier;
}

describe('assinatura da NFC-e do PDV', () => {
  it('a xml-crypto confere a assinatura e o trecho assinado é a infNFe', () => {
    const xml = readFileSync(fixture, 'utf8');
    const verifier = signatureOf(xml);
    expect(verifier.checkSignature(xml)).toBe(true);
    const [signed] = verifier.getSignedReferences();
    expect(signed).toMatch(/^<infNFe xmlns="http:\/\/www.portalfiscal.inf.br\/nfe" Id="NFe\d{44}" versao="4.00">/);
  });

  it('qualquer mudança no conteúdo invalida a assinatura', () => {
    const xml = readFileSync(fixture, 'utf8');
    const tampered = xml.replace('<vNF>30.00</vNF>', '<vNF>3.00</vNF>');
    expect(tampered).not.toBe(xml);
    let valid: boolean;
    try {
      valid = signatureOf(tampered).checkSignature(tampered);
    } catch {
      valid = false;
    }
    expect(valid).toBe(false);
  });
});
