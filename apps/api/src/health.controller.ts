import {
  Controller,
  Get,
  Logger,
  ServiceUnavailableException,
} from '@nestjs/common';
import { DatabaseService } from './database.service.js';

@Controller('health')
export class HealthController {
  private readonly logger = new Logger(HealthController.name);

  constructor(private readonly database: DatabaseService) {}

  @Get()
  async check(): Promise<{ status: string; database: string }> {
    try {
      await this.database.ping();
      return { status: 'ok', database: 'up' };
    } catch (error) {
      // O detalhe técnico fica só no log.
      this.logger.error('Falha ao conectar ao banco de dados', error);
      throw new ServiceUnavailableException(
        'Sistema indisponível no momento. Tente novamente em instantes.',
      );
    }
  }
}
