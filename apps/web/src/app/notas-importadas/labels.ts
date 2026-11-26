// Textos das NF-e de estoque importadas.

export const KIND_LABELS: Record<string, string> = {
  purchase: "Compra",
  customer_return: "Devolução de cliente",
  other_entry: "Outra entrada",
  own_entry: "Entrada emitida pela loja",
  supplier_return: "Devolução ao fornecedor",
  transfer: "Transferência",
  other_output: "Outra saída",
};

/** Entra (soma) ou sai (baixa) do estoque da filial da nota. */
export const ENTRY_KINDS = new Set(["purchase", "customer_return", "other_entry", "own_entry"]);

export const documentText = (value: string | null) => {
  if (!value) return "—";
  if (value.length === 14) return value.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, "$1.$2.$3/$4-$5");
  // CPF aparece mascarado: o detalhe completo fica no XML.
  if (value.length === 11) return `***.${value.slice(3, 6)}.${value.slice(6, 9)}-**`;
  return value;
};
