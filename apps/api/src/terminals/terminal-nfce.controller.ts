import {
  Body as RequestBody,
  Controller,
  HttpCode,
  Inject,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { asBody } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { signingMaterial } from '../fiscal/certificate.js';
import { open } from '../fiscal/secret-box.js';
import { AppError } from '../observability/app-error.js';
import { currentContext } from '../observability/request-context.js';
import { envelopeContext, sealForTerminal } from './credential-envelope.js';
import { isValidPublicKey, verifySignature } from './terminal-crypto.js';
import { requireActiveTerminal, TerminalGuard } from './terminal.guard.js';

const ONE_MINUTE = 60_000;

/** Texto assinado pela chave do terminal para registrar a chave de criptografia do caixa. */
export const fiscalKeyMessage = (terminalId: string, publicKey: string) =>
  `farmaerp-terminal-fiscal-key:${terminalId}:${publicKey}`;

interface DeliveryRow {
  terminal_id: string;
  company_id: string;
  branch_id: string;
  credential_version: string;
  fiscal_key: string;
  fingerprint: string;
  valid_to: string;
  encrypted_pfx: string;
  encrypted_password: string;
  csc_id: string;
  encrypted_csc: string;
}

function terminalId(): string {
  const id = currentContext()?.terminalId;
  if (!id) throw new AppError('FA306');
  return id;
}

/** Certificado A1 e CSC da NFC-e para o caixa, cifrados para a chave daquele caixa. */
@Controller('terminals/nfce')
@UseGuards(TerminalGuard)
export class TerminalNfceController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  /** A chave nova vale só com a assinatura da chave do terminal: ninguém registra chave no lugar dele. */
  @Post('key')
  @HttpCode(200)
  @Throttle({ default: { limit: 10, ttl: ONE_MINUTE } })
  async setKey(@RequestBody() rawBody: unknown) {
    const { publicKey, signature } = asBody(rawBody);
    const id = terminalId();
    const terminal = await requireActiveTerminal(this.database, id);
    if (!isValidPublicKey(publicKey) || !verifySignature(terminal.publicKey, fiscalKeyMessage(id, publicKey), signature)) {
      throw new AppError('FA731');
    }
    await this.database.withContext((client) => client.query('SELECT app.set_terminal_fiscal_key($1)', [publicKey]));
    return { status: 'ok' };
  }

  /**
   * Abre o certificado e o CSC só durante esta chamada e devolve tudo cifrado para o caixa.
   * Se algo falhar depois do registro da entrega, a transação desfaz o registro.
   */
  @Post('credentials')
  @HttpCode(200)
  @Throttle({ default: { limit: 6, ttl: ONE_MINUTE } })
  credentials() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: DeliveryRow }>('SELECT app.terminal_nfce_credentials() AS r');
      const row = rows[0].r;
      const certificateContext = `certificate:${row.company_id}`;
      const pfx = open(Buffer.from(row.encrypted_pfx, 'base64'), certificateContext);
      const password = open(Buffer.from(row.encrypted_password, 'base64'), certificateContext).toString('utf8');
      const csc = open(Buffer.from(row.encrypted_csc, 'base64'), `csc:${row.branch_id}`).toString('utf8');
      const material = signingMaterial(pfx, password);
      const plain = Buffer.from(JSON.stringify({
        credentialVersion: row.credential_version,
        fingerprint: row.fingerprint,
        validTo: row.valid_to,
        cscId: row.csc_id,
        csc,
        privateKey: material.privateKey,
        certificate: material.certificate,
      }), 'utf8');
      try {
        return {
          credentialVersion: row.credential_version,
          validTo: row.valid_to,
          envelope: sealForTerminal(plain, row.fiscal_key, envelopeContext(row.terminal_id, row.credential_version)),
        };
      } catch (cause) {
        throw new AppError('FA731', { cause });
      } finally {
        plain.fill(0);
        pfx.fill(0);
      }
    });
  }
}
