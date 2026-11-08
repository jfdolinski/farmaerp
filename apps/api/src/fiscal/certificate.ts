import { createHash } from 'node:crypto';
import forge from 'node-forge';
import { AppError } from '../observability/app-error.js';

export interface CertificateInfo {
  subjectName: string;
  cnpj: string;
  validFrom: string;
  validTo: string;
  fingerprint: string;
}

// CNPJ com números ou no formato alfanumérico.
const CNPJ = '[0-9A-Z]{12}[0-9]{2}';
const CN_CNPJ = new RegExp(`:(${CNPJ})$`);
// OID 2.16.76.1.3.3 (CNPJ do titular, ICP-Brasil) na extensão de nomes alternativos.
const SAN_CNPJ = new RegExp(`\\x06\\x05\\x60\\x4c\\x01\\x03\\x03[\\s\\S]{2,8}?(${CNPJ})`);
const SUBJECT_ALT_NAME = '2.5.29.17';

type Extension = { id?: string; value?: unknown };

function cnpjOf(certificate: forge.pki.Certificate, commonName: string): string | null {
  const fromName = CN_CNPJ.exec(commonName)?.[1];
  if (fromName) return fromName;
  const extension = (certificate.extensions as Extension[]).find((e) => e.id === SUBJECT_ALT_NAME);
  return typeof extension?.value === 'string' ? (SAN_CNPJ.exec(extension.value)?.[1] ?? null) : null;
}

function bagsOf(p12: forge.pkcs12.Pkcs12Pfx, bagType: string): forge.pkcs12.Bag[] {
  return p12.getBags({ bagType })[bagType] ?? [];
}

/**
 * Abre o .pfx e devolve os dados de exibição. O certificado escolhido é o que corresponde à
 * chave privada do arquivo, porque a cadeia da certificadora vem junto. Nada do titular além
 * do nome e do CNPJ é lido: o CPF do responsável, que também está no arquivo, não sai daqui.
 */
export function readCertificate(pfx: Buffer, password: string): CertificateInfo {
  let certificate: forge.pki.Certificate | undefined;
  try {
    const asn1 = forge.asn1.fromDer(forge.util.createBuffer(pfx.toString('binary')));
    const p12 = forge.pkcs12.pkcs12FromAsn1(asn1, true, password);
    const { pkcs8ShroudedKeyBag, keyBag, certBag } = forge.pki.oids;
    const key = [...bagsOf(p12, pkcs8ShroudedKeyBag), ...bagsOf(p12, keyBag)][0]?.key as
      | forge.pki.rsa.PrivateKey
      | undefined;
    if (key) {
      certificate = bagsOf(p12, certBag)
        .map((bag) => bag.cert)
        .find((cert): cert is forge.pki.Certificate => {
          const publicKey = cert?.publicKey as forge.pki.rsa.PublicKey | undefined;
          return publicKey?.n?.equals(key.n) === true && publicKey.e.equals(key.e);
        });
    }
  } catch (cause) {
    throw new AppError('FA912', { cause });
  }
  if (!certificate) {
    throw new AppError('FA912');
  }

  const commonName = String(certificate.subject.getField('CN')?.value ?? '').trim();
  const cnpj = cnpjOf(certificate, commonName);
  if (!cnpj) {
    // Abriu, mas não é um certificado de empresa (e-CPF, por exemplo).
    throw new AppError('FA913');
  }
  const der = forge.asn1.toDer(forge.pki.certificateToAsn1(certificate)).getBytes();
  return {
    subjectName: commonName,
    cnpj,
    validFrom: certificate.validity.notBefore.toISOString(),
    validTo: certificate.validity.notAfter.toISOString(),
    fingerprint: createHash('sha256').update(Buffer.from(der, 'binary')).digest('hex'),
  };
}
