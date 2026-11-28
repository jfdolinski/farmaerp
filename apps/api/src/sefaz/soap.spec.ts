import { createServer } from 'node:https';
import { AddressInfo } from 'node:net';
import { AppError } from '../observability/app-error.js';
import { localhostCertificate } from '../../test/fake-tls.js';
import { httpsCall, notReached, postSoap } from './soap.js';

describe('chamada à Sefaz', () => {
  it('sem conexão (porta fechada): FA944 marcado como "não chegou"', async () => {
    const error = await httpsCall('https://127.0.0.1:1/x', { method: 'POST', body: 'a' }, { pfx: undefined as unknown as Buffer, passphrase: '' }).catch((e) => e);
    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe('FA944');
    expect(notReached(error)).toBe(true);
  });

  it('conectou e a resposta veio com erro: FA944 sem a marca (a Sefaz pode ter recebido)', async () => {
    const tls = localhostCertificate();
    const server = createServer({ key: tls.key, cert: tls.cert }, (_req, res) => {
      res.writeHead(500);
      res.end();
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    try {
      const port = (server.address() as AddressInfo).port;
      const error = await postSoap(`https://localhost:${port}/x`, 'acao', '<x/>', { pfx: undefined as unknown as Buffer, passphrase: '' }, tls.cert)
        .catch((e) => e);
      expect((error as AppError).code).toBe('FA944');
      expect(notReached(error)).toBe(false);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  it('outros erros não são "não chegou"', () => {
    expect(notReached(new AppError('FA944'))).toBe(false);
    expect(notReached(new AppError('FA005', { detail: 'not_reached' }))).toBe(false);
    expect(notReached(new Error('x'))).toBe(false);
  });
});
