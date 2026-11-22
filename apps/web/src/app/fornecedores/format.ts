// Fora do "use client": as páginas de servidor também usam.

/** O banco devolve 1.000, que em português se lê como mil. */
export const fractionText = (value: string | number | null | undefined) =>
  value === null || value === undefined
    ? ""
    : Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3, useGrouping: false });

export const cnpjText = (cnpj: string) =>
  cnpj.length === 14
    ? `${cnpj.slice(0, 2)}.${cnpj.slice(2, 5)}.${cnpj.slice(5, 8)}/${cnpj.slice(8, 12)}-${cnpj.slice(12)}`
    : cnpj;
