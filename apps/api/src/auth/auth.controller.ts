import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import type { Request } from 'express';
import { asBody, requireText } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import {
  assertPasswordPolicy,
  generateSessionToken,
  hashPassword,
  hashSessionToken,
  spendVerificationTime,
  verifyPassword,
} from './password.js';
import {
  AllowPendingPasswordChange,
  type AuthenticatedRequest,
  SessionGuard,
} from './session.guard.js';

interface LoginLookup {
  userId: string;
  passwordHash: string;
  locked: boolean;
}

@Controller('auth')
export class AuthController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Post('login')
  @HttpCode(200)
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  async login(@RequestBody() rawBody: unknown, @Req() request: Request) {
    const body = asBody(rawBody);
    const email = requireText(body, 'email', 254);
    const password = requireText(body, 'password', 200);
    const ip = request.ip ?? '';

    const lookup = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: LoginLookup | null }>(
        'SELECT app.auth_lookup($1) AS result',
        [email],
      );
      return rows[0].result;
    });

    // E-mail desconhecido, conta bloqueada e senha errada: mesma resposta e mesmo tempo.
    let valid = false;
    if (lookup && !lookup.locked) {
      valid = await verifyPassword(lookup.passwordHash, password);
    } else {
      await spendVerificationTime(password);
    }

    if (!valid) {
      await this.database.withContext((client) =>
        client.query('SELECT app.auth_login_failed($1, $2)', [
          lookup?.userId ?? null,
          ip,
        ]),
      );
      throw new AppError('FA401');
    }

    const token = generateSessionToken();
    const session = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{
        result: { mustChangePassword: boolean };
      }>('SELECT app.auth_login_succeeded($1, $2, $3) AS result', [
        lookup!.userId,
        hashSessionToken(token),
        ip,
      ]);
      return rows[0].result;
    });

    return { token, mustChangePassword: session.mustChangePassword };
  }

  @Post('logout')
  @HttpCode(200)
  @UseGuards(SessionGuard)
  @AllowPendingPasswordChange()
  async logout(@Req() request: AuthenticatedRequest) {
    await this.database.withContext((client) =>
      client.query('SELECT app.end_session($1, $2)', [
        request.sessionTokenHash,
        request.ip ?? '',
      ]),
    );
    return { status: 'ok' };
  }

  @Get('me')
  @UseGuards(SessionGuard)
  @AllowPendingPasswordChange()
  me(@Req() request: AuthenticatedRequest) {
    return request.sessionUser;
  }

  @Post('change-password')
  @HttpCode(200)
  @UseGuards(SessionGuard)
  @AllowPendingPasswordChange()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  async changePassword(
    @RequestBody() rawBody: unknown,
    @Req() request: AuthenticatedRequest,
  ) {
    const body = asBody(rawBody);
    const currentPassword = requireText(body, 'currentPassword', 200);
    const newPassword = requireText(body, 'newPassword', 200);
    assertPasswordPolicy(newPassword, request.sessionUser?.email);

    const currentHash = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ hash: string | null }>(
        'SELECT app.current_password_hash() AS hash',
      );
      return rows[0].hash;
    });
    if (!currentHash || !(await verifyPassword(currentHash, currentPassword))) {
      throw new AppError('FA409');
    }
    if (await verifyPassword(currentHash, newPassword)) {
      throw new AppError('FA404');
    }

    const newHash = await hashPassword(newPassword);
    await this.database.withContext((client) =>
      client.query('SELECT app.change_own_password($1, $2, $3)', [
        newHash,
        request.sessionTokenHash,
        request.ip ?? '',
      ]),
    );
    return { status: 'ok' };
  }
}
