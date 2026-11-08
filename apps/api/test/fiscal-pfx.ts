// Só para testes: gera um .pfx autoassinado, sem dados de ninguém.
import { generateKeyPairSync } from 'node:crypto';
import forge from 'node-forge';

const DAY = 24 * 60 * 60 * 1000;
// A geração de chave é lenta; todos os testes usam o mesmo par.
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

export interface TestPfxOptions {
  commonName?: string;
  password?: string;
  daysLeft?: number;
  /** CNPJ gravado no OID da ICP-Brasil, em vez do nome. */
  sanCnpj?: string;
  algorithm?: 'aes256' | '3des';
}

export function buildPfx(options: TestPfxOptions = {}): Buffer {
  const { commonName = 'EMPRESA TESTE:11222333000181', password = 'senha-do-teste', daysLeft = 200 } = options;
  const certificate = forge.pki.createCertificate();
  certificate.publicKey = forge.pki.publicKeyFromPem(publicKey);
  certificate.serialNumber = '01';
  certificate.validity.notBefore = new Date(Date.now() - 400 * DAY);
  certificate.validity.notAfter = new Date(Date.now() + daysLeft * DAY);
  const attributes = [{ name: 'commonName', value: commonName }];
  certificate.setSubject(attributes);
  certificate.setIssuer(attributes);
  if (options.sanCnpj) {
    const { asn1 } = forge;
    const otherName = asn1.create(asn1.Class.CONTEXT_SPECIFIC, 0, true, [
      asn1.create(asn1.Class.UNIVERSAL, asn1.Type.OID, false, asn1.oidToDer('2.16.76.1.3.3').getBytes()),
      asn1.create(asn1.Class.CONTEXT_SPECIFIC, 0, true, [
        asn1.create(asn1.Class.UNIVERSAL, asn1.Type.PRINTABLESTRING, false, options.sanCnpj),
      ]),
    ]);
    certificate.setExtensions([{
      id: '2.5.29.17',
      value: asn1.toDer(asn1.create(asn1.Class.UNIVERSAL, asn1.Type.SEQUENCE, true, [otherName])).getBytes(),
    }]);
  }
  const key = forge.pki.privateKeyFromPem(privateKey);
  certificate.sign(key, forge.md.sha256.create());
  const p12 = forge.pkcs12.toPkcs12Asn1(key, [certificate], password, { algorithm: options.algorithm ?? '3des' });
  return Buffer.from(forge.asn1.toDer(p12).getBytes(), 'binary');
}
