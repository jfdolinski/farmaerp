export const REGIMES: [number, string][] = [
  [1, "Simples Nacional"],
  [2, "Simples Nacional, excesso de sublimite"],
  [3, "Regime Normal"],
  [4, "MEI"],
];

export const regimeLabel = (code: number | null) =>
  REGIMES.find(([value]) => value === code)?.[1] ?? "Não informado";
