// Fora do "use client": as páginas de servidor também usam.

export const STATUS_LABELS: Record<string, string> = {
  review: "Em conferência",
  not_postable: "Não vai para o estoque",
  posted: "Lançada no estoque",
  cancelled: "Cancelada",
};

/** Confirmação pela Sefaz: o resumo da assinatura bate com o que a Sefaz autorizou. */
export const CONFIRMATION_LABELS: Record<string, string> = {
  pending: "Aguardando confirmação da Sefaz",
  confirmed: "Confirmada pela Sefaz",
  mismatch: "Diferente do que a Sefaz autorizou",
  unavailable: "A Sefaz não confirmou",
};

/** Custo unitário com até quatro casas: o custo fracionado costuma ter centavos quebrados. */
export const costText = (value: string | number | null) =>
  value === null
    ? ""
    : Number(value).toLocaleString("pt-BR", {
        style: "currency",
        currency: "BRL",
        minimumFractionDigits: 2,
        maximumFractionDigits: 4,
      });

export const percentText = (value: string | number | null) =>
  value === null ? "" : `${Number(value) > 0 ? "+" : ""}${Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 2 })}%`;

export const REASON_LABELS: Record<string, string> = {
  purpose: "A finalidade da nota não é de compra normal (complementar, ajuste ou devolução).",
  entry: "É uma nota de entrada, emitida por quem recebe a mercadoria.",
  own_branch: "Foi emitida por uma filial da própria rede. A transferência já mexe no estoque pela tela de Estoque.",
};

export const SOURCE_LABELS: Record<string, string> = {
  supplier_code: "Pelo código do fornecedor",
  barcode: "Pelo código de barras",
  manual: "Ligado na conferência",
  duplicate: "Cadastro duplicado na conferência",
  catalog: "Cadastrado pelo Catálogo na conferência",
};

export const moneyText = (value: string | number | null) =>
  value === null ? "" : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

export const quantityText = (value: string | number | null) =>
  value === null ? "" : Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 4 });

export const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

export const dateText = (value: string) =>
  new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" });

/** A validade chega como AAAA-MM-DD: trocar a ordem evita qualquer conversão de fuso. */
export const dayText = (value: string | null) => (value ? value.split("-").reverse().join("/") : "");

/** Chave em blocos de quatro, como no DANFE. */
export const keyText = (key: string) => key.replace(/(.{4})/g, "$1 ").trim();
