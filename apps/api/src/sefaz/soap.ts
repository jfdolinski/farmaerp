import { request } from 'node:https';
import { AppError } from '../observability/app-error.js';

const MAX_RESPONSE_BYTES = 20 * 1024 * 1024;
const TIMEOUT_MS = 30_000;

export interface ClientCertificate {
  pfx: Buffer;
  passphrase: string;
}

/**
 * Chamada SOAP 1.2 com o certificado A1 da filial no TLS. Qualquer falha de rede, resposta que não
 * seja 200 ou resposta grande demais vira FA944; a causa técnica vai só para o log, sem o certificado.
 */
export function postSoap(
  url: string,
  action: string,
  envelope: string,
  certificate: ClientCertificate,
  ca?: string,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const fail = (reason: string) => reject(new AppError('FA944', { cause: new Error(reason) }));
    const body = Buffer.from(envelope, 'utf8');
    const req = request(
      url,
      {
        method: 'POST',
        pfx: certificate.pfx,
        passphrase: certificate.passphrase,
        ...(ca ? { ca } : {}),
        minVersion: 'TLSv1.2',
        timeout: TIMEOUT_MS,
        headers: {
          'Content-Type': `application/soap+xml; charset=utf-8; action="${action}"`,
          'Content-Length': body.length,
        },
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
          if (res.statusCode !== 200) {
            fail(`HTTP ${res.statusCode ?? 'sem código'}`);
            return;
          }
          resolve(Buffer.concat(chunks).toString('utf8'));
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
