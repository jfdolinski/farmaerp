import Link from "next/link";
import { regimeLabel } from "../fiscal/regimes";
import { dayText } from "../estoque/format";
import styles from "../terminais/page.module.css";

export interface TaxRow {
  branch_id: string;
  branch_name: string;
  status: "ok" | "no_catalog" | "no_regime" | "no_state" | "no_rule";
  tax_regime: number | null;
  state: string | null;
  tax_id: string | null;
  valid_from: string | null;
  cfop: string | null;
  origin: number | null;
  benefit_code: string | null;
  icms_cst: string | null;
  icms_csosn: string | null;
  icms_rate: string | null;
  icms_base_reduction: string | null;
  fcp_rate: string | null;
  st_base_mode: number | null;
  st_mva: string | null;
  st_rate: string | null;
  st_base_reduction: string | null;
  st_fcp_rate: string | null;
  pis_cst: string | null;
  pis_rate: string | null;
  cofins_cst: string | null;
  cofins_rate: string | null;
  ibs_cbs_cst: string | null;
  class_trib: string | null;
  ibs_state_rate: string | null;
  ibs_city_rate: string | null;
  cbs_rate: string | null;
  ibs_cbs_reduction: string | null;
}

const ST_BASE_MODES = [
  "Preço tabelado",
  "Lista negativa",
  "Lista positiva",
  "Lista neutra",
  "MVA",
  "Pauta",
  "Valor da operação",
];

const percent = (label: string, value: string | null) =>
  value === null
    ? null
    : `${label} ${Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 4 })}%`;

const join = (parts: (string | null | false)[]) => parts.filter(Boolean).join(" · ");

function missingText(row: TaxRow) {
  switch (row.status) {
    case "no_catalog":
      return "O produto não está vinculado ao Catálogo.";
    case "no_regime":
      return "A empresa ainda não tem regime informado.";
    case "no_state":
      return "A filial ainda não tem estado informado.";
    default:
      return `O Catálogo não tem regra para ${regimeLabel(row.tax_regime)} em ${row.state}.`;
  }
}

function missingLink(status: TaxRow["status"]) {
  if (status === "no_regime") return <Link href="/fiscal">Informar em Fiscal</Link>;
  if (status === "no_state") return <Link href="/empresas">Informar em Empresas e filiais</Link>;
  return null;
}

function TaxDetails({ row }: { row: TaxRow }) {
  const icmsCode = row.icms_cst ? `CST ${row.icms_cst}` : `CSOSN ${row.icms_csosn}`;
  const hasSt = row.st_base_mode !== null || row.st_rate !== null;
  const lines: [string, string][] = [
    [
      "Operação",
      join([`CFOP ${row.cfop}`, `Origem ${row.origin}`, row.benefit_code && `cBenef ${row.benefit_code}`]),
    ],
    [
      "ICMS",
      join([
        icmsCode,
        percent("Alíquota", row.icms_rate),
        percent("Redução da base", row.icms_base_reduction),
        percent("FCP", row.fcp_rate),
      ]),
    ],
    [
      "ST",
      hasSt
        ? join([
            row.st_base_mode !== null && ST_BASE_MODES[row.st_base_mode],
            percent("MVA", row.st_mva),
            percent("Alíquota", row.st_rate),
            percent("Redução da base", row.st_base_reduction),
            percent("FCP-ST", row.st_fcp_rate),
          ])
        : row.icms_cst === "60" || row.icms_csosn === "500"
          ? "Já recolhida antes. Os valores retidos vêm da nota de compra"
          : "Sem ST nesta venda",
    ],
    ["PIS", join([`CST ${row.pis_cst}`, percent("Alíquota", row.pis_rate)])],
    ["COFINS", join([`CST ${row.cofins_cst}`, percent("Alíquota", row.cofins_rate)])],
    [
      "IBS/CBS",
      row.ibs_cbs_cst
        ? join([
            `CST ${row.ibs_cbs_cst}`,
            `cClassTrib ${row.class_trib}`,
            percent("IBS UF", row.ibs_state_rate),
            percent("IBS municipal", row.ibs_city_rate),
            percent("CBS", row.cbs_rate),
            percent("Redução", row.ibs_cbs_reduction),
          ])
        : "Não informado",
    ],
  ];
  return (
    <div className={styles.tableWrap}>
      <table>
        <tbody>
          {lines.map(([label, text]) => (
            <tr key={label}>
              <th scope="row">{label}</th>
              <td>{text}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Filiais com o mesmo regime e UF têm a mesma regra: aparecem juntas, para a tela não se repetir.
export function ProductTax({ rows }: { rows: TaxRow[] }) {
  const groups = new Map<string, TaxRow[]>();
  for (const row of rows) {
    const key = [row.status, row.tax_regime, row.state, row.tax_id].join("|");
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return (
    <>
      {[...groups.entries()].map(([key, branches]) => {
        const row = branches[0];
        return (
          <div key={key} className={styles.stack}>
            <h3>{branches.map((branch) => branch.branch_name).join(", ")}</h3>
            {row.status === "ok" ? (
              <>
                <p className={styles.hint}>
                  {regimeLabel(row.tax_regime)} em {row.state}. Vigente desde {dayText(row.valid_from)}.
                </p>
                <TaxDetails row={row} />
              </>
            ) : (
              <p className={styles.warning} role="status">
                Sem tributação. {missingText(row)} {missingLink(row.status)}
              </p>
            )}
          </div>
        );
      })}
    </>
  );
}
