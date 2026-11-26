// Textos das vendas importadas: formas de pagamento e bandeiras como vêm na nota (tPag e tBand).

export const NOTE_PAYMENT_LABELS: Record<string, string> = {
  "01": "Dinheiro",
  "02": "Cheque",
  "03": "Cartão de crédito",
  "04": "Cartão de débito",
  "05": "Crédito loja",
  "10": "Vale alimentação",
  "11": "Vale refeição",
  "12": "Vale presente",
  "13": "Vale combustível",
  "15": "Boleto",
  "16": "Depósito",
  "17": "PIX",
  "18": "Transferência",
  "19": "Fidelidade/cashback",
  "20": "PIX estático",
  "21": "Crédito em loja",
  "22": "Pagamento eletrônico não informado",
  "90": "Sem pagamento",
  "99": "Outros",
};

export const CARD_BRAND_LABELS: Record<string, string> = {
  "01": "Visa",
  "02": "Mastercard",
  "03": "American Express",
  "04": "Sorocred",
  "05": "Diners",
  "06": "Elo",
  "07": "Hipercard",
  "08": "Aura",
  "09": "Cabal",
  "99": "Outra",
};

export const noteText = (model: string, series: number, number: number | string) =>
  `${model === "65" ? "NFC-e" : "NF-e"} ${series}/${number}`;
