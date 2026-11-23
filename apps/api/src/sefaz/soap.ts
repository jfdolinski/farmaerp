import { request } from 'node:https';
import { AppError } from '../observability/app-error.js';

const MAX_RESPONSE_BYTES = 20 * 1024 * 1024;
const TIMEOUT_MS = 30_000;

export interface ClientCertificate {
  pfx: Buffer;
  passphrase: string;
}

export interface HttpsResult {
  status: number;
  body: string;
}

/**
 * Chamada HTTPS com o certificado A1 da filial no TLS. Falha de rede, tempo esgotado ou resposta
 * grande demais vira FA944; a causa técnica vai só para o log, sem o certificado.
 */
export function httpsCall(
  url: string,
  options: { method: 'GET' | 'POST'; headers?: Record<string, string | number>; body?: string },
  certificate: ClientCertificate,
  ca?: string,
): Promise<HttpsResult> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const fail = (reason: string) => {
      if (settled) return;
      settled = true;
      reject(new AppError('FA944', { cause: new Error(reason) }));
    };
    const body = options.body === undefined ? undefined : Buffer.from(options.body, 'utf8');
    const req = request(
      url,
      {
        method: options.method,
        pfx: certificate.pfx,
        passphrase: certificate.passphrase,
        ...(ca ? { ca } : {}),
        minVersion: 'TLSv1.2',
        timeout: TIMEOUT_MS,
        headers: { ...options.headers, ...(body ? { 'Content-Length': body.length } : {}) },
      },
      (res) => {
        const chunks: Buffer[] = [];
        let size = 0;
        res.on('data', (chunk: Buffer) => {
          size += chunk.length;
          if (size > MAX_RESPONSE_BYTES) {
            req.destroy();
            fail('resposta grande demais');
            return;
          }
          chunks.push(chunk);
        });
        res.on('end', () => {
          if (settled) return;
          settled = true;
          resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') });
        });
        res.on('error', (error) => fail(`resposta: ${error.message}`));
      },
    );
    req.on('timeout', () => {
      req.destroy();
      fail('tempo esgotado');
    });
    req.on('error', (error) => fail(`conexão: ${(error as NodeJS.ErrnoException).code ?? error.message}`));
    req.end(body);
  });
}

/** Chamada SOAP 1.2 da Sefaz. Resposta que não seja 200 também vira FA944. */
export async function postSoap(
  url: string,
  action: string,
  envelope: string,
  certificate: ClientCertificate,
  ca?: string,
): Promise<string> {
  const result = await httpsCall(
    url,
    { method: 'POST', headers: { 'Content-Type': `application/soap+xml; charset=utf-8; action="${action}"` }, body: envelope },
    certificate,
    ca,
  );
  if (result.status !== 200) {
    throw new AppError('FA944', { cause: new Error(`HTTP ${result.status}`) });
  }
  return result.body;
}
