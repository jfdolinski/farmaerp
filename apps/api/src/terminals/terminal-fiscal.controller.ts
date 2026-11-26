import { Body as RequestBody, Controller, HttpCode, Inject, Param, Post, UseGuards } from '@nestjs/common';
import { asBody, requireText, requireUuid } from '../common/parse.js';
import { NfceActionsService } from '../fiscal/nfce-actions.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

/** Cancelamento da NFC-e pedido pelo caixa: a central fala com a Sefaz e desfaz a venda. */
@Controller('terminals/fiscal-documents')
@UseGuards(TerminalGuard)
export class TerminalFiscalController {
  constructor(@Inject(NfceActionsService) private readonly actions: NfceActionsService) {}

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const reason = requireText(body, 'reason', 255).trim();
    if (reason.length < 15) throw new AppError('FA005');
    return this.actions.cancelForTerminal(requireUuid(id), requireUuid(body.supervisorId), reason);
  }
}
