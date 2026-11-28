import { randomUUID } from 'node:crypto';
import { AppError } from '../observability/app-error.js';

/** Item do carrinho que o caixa pede ao programa: quantidade e preço unitário do caixa. */
export interface PbmItemRequest {
  productId: string;
  quantity: number;
  unitPrice: number;
}

/** Item que o programa aceitou, com o preço unitário que o cliente paga. */
export interface PbmItemQuote {
  productId: string;
  quantity: number;
  listPrice: number;
  pbmPrice: number;
}

export interface PbmQuote {
  /** Código da autorização no programa (para confirmar ou desfazer). */
  externalId: string;
  items: PbmItemQuote[];
}

/** O que o conector recebe: os dados de acesso da filial (já abertos) e, no de teste, as regras. */
export interface PbmCall {
  credentials: Record<string, string> | null;
  /** Regras do programa de teste para os produtos pedidos (percentual por produto). */
  testRules: (productIds: string[]) => Promise<Map<string, number>>;
}

/**
 * Conversa com um programa de benefício. Cada programa real (com contrato e documentação) vira uma
 * implementação; o fluxo do caixa é sempre o mesmo: autoriza, confirma depois do pagamento ou desfaz.
 * Falhas: FA794 (beneficiário sem direito), FA796 (nenhum item no programa), FA797 (programa fora do ar).
 */
export interface PbmConnector {
  authorize(call: PbmCall, beneficiary: string, items: PbmItemRequest[]): Promise<PbmQuote>;
  confirm(call: PbmCall, externalId: string, saleId: string): Promise<void>;
  undo(call: PbmCall, externalId: string, reason: string): Promise<void>;
}

const cents = (value: number) => Math.round(value * 100) / 100;

/**
 * Programa de teste (homologação e treino): responde como um programa real, sem sair da central.
 * - documento terminado em 0: beneficiário sem direito (FA794);
 * - documento começando com FORA: programa fora do ar (FA797);
 * - entram só os produtos com regra no programa, com o percentual da regra.
 */
export class TestPbmConnector implements PbmConnector {
  async authorize(call: PbmCall, beneficiary: string, items: PbmItemRequest[]): Promise<PbmQuote> {
    if (beneficiary.startsWith('FORA')) throw new AppError('FA797', { cause: new Error('programa de teste fora do ar') });
    if (beneficiary.endsWith('0')) throw new AppError('FA794');
    const rules = await call.testRules(items.map((item) => item.productId));
    const accepted = items
      .filter((item) => rules.has(item.productId))
      .map((item) => ({
        productId: item.productId,
        quantity: item.quantity,
        listPrice: item.unitPrice,
        pbmPrice: cents(item.unitPrice * (1 - (rules.get(item.productId) ?? 0) / 100)),
      }));
    if (accepted.length === 0) throw new AppError('FA796');
    return { externalId: `TESTE-${randomUUID().slice(0, 13).toUpperCase()}`, items: accepted };
  }

  async confirm(): Promise<void> {}

  async undo(): Promise<void> {}
}

export const PBM_CONNECTORS: Record<string, PbmConnector> = {
  test: new TestPbmConnector(),
};
