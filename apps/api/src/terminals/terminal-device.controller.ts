import {
  Body as RequestBody,
  Controller,
  HttpCode,
  Inject,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  asBody,
  optionalCount,
  optionalInstant,
  optionalText,
  requireText,
  requireUuid,
} from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import {
  challengeMessage,
  isValidPublicKey,
  issueAccessToken,
  issueChallenge,
  pairingProofMessage,
  verifyChallenge,
  verifySignature,
} from './terminal-crypto.js';
import { requireActiveTerminal, TerminalGuard } from './terminal.guard.js';

const ONE_MINUTE = 60_000;

/** Rotas usadas pelo aparelho, que ainda não tem usuário logado. */
@Controller('terminals')
export class TerminalDeviceController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Post('pairing/requests')
  @Throttle({ default: { limit: 10, ttl: ONE_MINUTE } })
  async createRequest(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const publicKey = body.publicKey;
    if (
      !isValidPublicKey(publicKey) ||
      !verifySignature(publicKey, pairingProofMessage(publicKey), body.signature)
    ) {
      throw new AppError('FA308');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>(
        'SELECT app.create_pairing_request($1, $2, $3, $4, $5) AS result',
        [
          publicKey,
          requireText(body, 'platform', 20),
          requireText(body, 'deviceName', 100),
          requireText(body, 'appVersion', 50),
          requireText(body, 'keyStorage', 20),
        ],
      );
      return rows[0].result;
    });
  }

  @Post('pairing/status')
  @HttpCode(200)
  @Throttle({ default: { limit: 60, ttl: ONE_MINUTE } })
  async pairingStatus(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    if (!isValidPublicKey(body.publicKey)) {
      throw new AppError('FA308');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>(
        'SELECT app.get_pairing_status($1, $2) AS result',
        [requireUuid(body.requestId), body.publicKey],
      );
      return rows[0].result;
    });
  }

  @Post('auth/challenge')
  @HttpCode(200)
  @Throttle({ default: { limit: 30, ttl: ONE_MINUTE } })
  async challenge(@RequestBody() rawBody: unknown) {
    const terminalId = requireUuid(asBody(rawBody).terminalId);
    await requireActiveTerminal(this.database, terminalId);
    const { value, expiresAt } = issueChallenge(terminalId);
    return { challenge: value, expiresAt };
  }

  @Post('auth/token')
  @HttpCode(200)
  @Throttle({ default: { limit: 30, ttl: ONE_MINUTE } })
  async token(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const verified = verifyChallenge(body.challenge);
    if (!verified) {
      throw new AppError('FA306');
    }
    const { publicKey } = await requireActiveTerminal(
      this.database,
      verified.terminalId,
    );
    if (
      !verifySignature(
        publicKey,
        challengeMessage(body.challenge as string),
        body.signature,
      )
    ) {
      throw new AppError('FA306');
    }
    const { value, expiresAt } = issueAccessToken(verified.terminalId);
    return { accessToken: value, expiresAt };
  }

  @Post('heartbeat')
  @HttpCode(200)
  @UseGuards(TerminalGuard)
  async heartbeat(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    await this.database.withContext(async (client) => {
      await client.query('SELECT app.record_terminal_heartbeat($1, $2, $3)', [
        optionalText(body, 'appVersion', 50),
        optionalInstant(body, 'lastSyncAt'),
        optionalCount(body, 'outboxPending'),
      ]);
    });
    return { status: 'active' };
  }
}
