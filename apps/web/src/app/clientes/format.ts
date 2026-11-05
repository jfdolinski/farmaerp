// Fica fora dos componentes de cliente porque as páginas do servidor também usam estes textos.

export const RELATIONSHIPS: Record<string, string> = {
  spouse: "Cônjuge",
  child: "Filho(a)",
  parent: "Pai ou mãe",
  sibling: "Irmão(ã)",
  grandchild: "Neto(a)",
  grandparent: "Avô ou avó",
  other: "Outro",
};

export const PURPOSES: Record<string, string> = {
  marketing: "Marketing",
  facial_recognition: "Reconhecimento facial",
  cashback: "Cashback",
};

export const CHANNELS: Record<string, string> = {
  store: "Na loja",
  phone: "Telefone",
  whatsapp: "WhatsApp",
  app: "Aplicativo",
  website: "Site",
};

export const STATES = [
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA", "MG", "MS", "MT", "PA",
  "PB", "PE", "PI", "PR", "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO",
];

/** O documento completo só aparece na ficha. */
export function documentText(document: string) {
  if (document.length === 11) {
    return `${document.slice(0, 3)}.${document.slice(3, 6)}.${document.slice(6, 9)}-${document.slice(9)}`;
  }
  if (document.length === 14) {
    return `${document.slice(0, 2)}.${document.slice(2, 5)}.${document.slice(5, 8)}/${document.slice(8, 12)}-${document.slice(12)}`;
  }
  return document;
}

/** A data chega como AAAA-MM-DD: trocar a ordem evita qualquer conversão de fuso. */
export const dayText = (value: string | null) =>
  value ? value.split("-").reverse().join("/") : "";
