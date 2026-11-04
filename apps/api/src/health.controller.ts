import { Controller, Get, Inject } from '@nestjs/common';
import { DatabaseService } from './database.service.js';
import { AppError } from './observability/app-error.js';

@Controller('health')
export class HealthController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  async check(): Promise<{ status: string; database: string }> {
    try {
      await this.database.ping();
    } catch (cause) {
      throw new AppError('FA001', { cause });
    }
    return { status: 'ok', database: 'up' };
  }
}
