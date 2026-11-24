import { brl } from "../vendas/labels";

/** Diferença do fechamento: sobra (+) ou falta (−). */
export function differenceText(value: string | number | null): string {
  if (value === null) return "—";
  const number = Number(value);
  if (number === 0) return "Sem diferença";
  return number > 0 ? `Sobra de ${brl(number)}` : `Falta de ${brl(-number)}`;
}
