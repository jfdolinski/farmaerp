// Fora do "use client": as páginas de servidor usam.

export const SERVICE_STATUS_LABELS: Record<string, string> = {
  active: "Válida",
  cancelled: "Cancelada pelo prestador",
  replaced: "Substituída",
};

/** tpRetISSQN do leiaute nacional. */
export const ISS_WITHHOLDING_LABELS: Record<number, string> = {
  1: "ISS não retido",
  2: "ISS retido pelo tomador",
  3: "ISS retido pelo intermediário",
};

/** tpRetPisCofins do leiaute nacional, como no DANFSe da Receita Federal. */
export const PIS_COFINS_WITHHOLDING_LABELS: Record<number, string> = {
  0: "PIS, COFINS e CSLL não retidos",
  1: "PIS e COFINS retidos",
  2: "PIS e COFINS não retidos",
  3: "PIS, COFINS e CSLL retidos",
  4: "PIS e COFINS retidos, CSLL não retida",
  5: "PIS retido, COFINS e CSLL não retidos",
  6: "COFINS retida, PIS e CSLL não retidos",
  7: "PIS não retido, COFINS e CSLL retidos",
  8: "PIS e COFINS não retidos, CSLL retida",
  9: "COFINS não retida, PIS e CSLL retidos",
};

export const moneyText = (value: string | number | null) =>
  value === null ? "" : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

export const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

/** Data AAAA-MM-DD: trocar a ordem evita qualquer conversão de fuso. */
export const dayText = (value: string | null) => (value ? value.split("-").reverse().join("/") : "");

/** Competência em mês/ano. */
export const competenceText = (value: string) => {
  const [year, month] = value.split("-");
  return `${month}/${year}`;
};

export const documentText = (value: string | null) => {
  if (!value) return "Sem CNPJ ou CPF";
  if (value.length === 14) return value.replace(/^(.{2})(.{3})(.{3})(.{4})(.{2})$/, "$1.$2.$3/$4-$5");
  if (value.length === 11) return value.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4");
  return value;
};

/** Mês atual, para o filtro começar no período de trabalho. */
export function currentMonth(now = new Date()): { from: string; to: string } {
  const local = new Date(now.toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
  const year = local.getFullYear();
  const month = local.getMonth() + 1;
  const last = new Date(year, month, 0).getDate();
  const pad = (value: number) => String(value).padStart(2, "0");
  return { from: `${year}-${pad(month)}-01`, to: `${year}-${pad(month)}-${pad(last)}` };
}
