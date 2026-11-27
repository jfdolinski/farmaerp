"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import { FiscalFormState, resetReturnTax, setReturnTax } from "./actions";

export interface ReturnTaxRow {
  branch_id: string;
  branch_name: string;
  settings: Record<string, string>;
  customized: boolean;
  can_manage: boolean;
}

/** Valores aceitos pelo banco, com o nome curto para a tela. */
const CSOSN: [string, string][] = [
  ["102", "102 · sem permissão de crédito"],
  ["103", "103 · isenção do ICMS para faixa de receita"],
  ["300", "300 · imune"],
  ["400", "400 · não tributada"],
  ["500", "500 · ICMS cobrado antes por ST"],
];
const CST: [string, string][] = [
  ["00", "00 · tributada integralmente"],
  ["40", "40 · isenta"],
  ["41", "41 · não tributada"],
  ["50", "50 · suspensão"],
  ["60", "60 · ICMS cobrado antes por ST"],
];
const PIS_COFINS: [string, string][] = [
  ["04", "04 · monofásica, alíquota zero"],
  ["05", "05 · substituição tributária"],
  ["06", "06 · alíquota zero"],
  ["07", "07 · isenta"],
  ["08", "08 · sem incidência"],
  ["09", "09 · suspensão"],
  ["49", "49 · outras operações de saída"],
  ["99", "99 · outras operações"],
];

function Choice({
  name,
  label,
  options,
  value,
  disabled,
}: {
  name: string;
  label: string;
  options: [string, string][];
  value: string;
  disabled: boolean;
}) {
  return (
    <label>
      {label}
      <select name={name} defaultValue={value} disabled={disabled}>
        {options.map(([code, text]) => (
          <option key={code} value={code}>
            {text}
          </option>
        ))}
      </select>
    </label>
  );
}

function Cfop({
  name,
  label,
  value,
  first,
  disabled,
}: {
  name: string;
  label: string;
  value: string;
  first: "5" | "6";
  disabled: boolean;
}) {
  return (
    <label>
      {label}
      <input
        name={name}
        defaultValue={value}
        required
        inputMode="numeric"
        pattern={`${first}[0-9]{3}`}
        title={`Quatro dígitos, começando com ${first}`}
        size={6}
        maxLength={4}
        disabled={disabled}
      />
    </label>
  );
}

/** Padrões da NF-e de devolução ao fornecedor de uma filial. */
export function ReturnTaxForm({ row }: { row: ReturnTaxRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setReturnTax, {});
  const [resetState, reset, resetting] = useActionState<FiscalFormState, FormData>(resetReturnTax, {});
  const values = row.settings;
  const locked = !row.can_manage;
  return (
    <div className={styles.stack}>
      {/* A chave muda quando os valores mudam: o formulário mostra o que está gravado. */}
      <form key={JSON.stringify(values)} action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <input type="hidden" name="branchId" value={row.branch_id} />
        <fieldset className={styles.fieldset}>
          <legend>CFOP</legend>
          <div className={styles.inline}>
            <Cfop
              name="cfop_internal"
              label="Dentro do estado"
              value={values.cfop_internal}
              first="5"
              disabled={locked}
            />
            <Cfop
              name="cfop_interstate"
              label="Fora do estado"
              value={values.cfop_interstate}
              first="6"
              disabled={locked}
            />
            <Cfop
              name="cfop_st_internal"
              label="Com ST, dentro do estado"
              value={values.cfop_st_internal}
              first="5"
              disabled={locked}
            />
            <Cfop
              name="cfop_st_interstate"
              label="Com ST, fora do estado"
              value={values.cfop_st_interstate}
              first="6"
              disabled={locked}
            />
          </div>
        </fieldset>
        <fieldset className={styles.fieldset}>
          <legend>ICMS</legend>
          <div className={styles.inline}>
            <Choice
              name="simples_csosn"
              label="Simples Nacional"
              options={CSOSN}
              value={values.simples_csosn}
              disabled={locked}
            />
            <Choice
              name="simples_csosn_st"
              label="Simples Nacional, com ST"
              options={CSOSN}
              value={values.simples_csosn_st}
              disabled={locked}
            />
            <Choice name="normal_cst" label="Regime normal" options={CST} value={values.normal_cst} disabled={locked} />
            <Choice
              name="normal_cst_st"
              label="Regime normal, com ST"
              options={CST}
              value={values.normal_cst_st}
              disabled={locked}
            />
          </div>
        </fieldset>
        <fieldset className={styles.fieldset}>
          <legend>PIS e COFINS</legend>
          <div className={styles.inline}>
            <Choice name="pis_cst" label="PIS" options={PIS_COFINS} value={values.pis_cst} disabled={locked} />
            <Choice name="cofins_cst" label="COFINS" options={PIS_COFINS} value={values.cofins_cst} disabled={locked} />
          </div>
        </fieldset>
        {row.can_manage && (
          <div className={styles.inline}>
            <button type="submit" disabled={pending || resetting}>
              {pending ? "Salvando..." : "Salvar padrões"}
            </button>
          </div>
        )}
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Padrões salvos. Valem para as próximas NF-e de devolução desta filial.
          </p>
        )}
      </form>
      {row.can_manage && row.customized && (
        <form action={reset}>
          <input type="hidden" name="branchId" value={row.branch_id} />
          <button type="submit" disabled={pending || resetting}>
            {resetting ? "Voltando..." : "Voltar aos padrões de fábrica"}
          </button>
          <ErrorNotice error={resetState.error} />
        </form>
      )}
    </div>
  );
}
