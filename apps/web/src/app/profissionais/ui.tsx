"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import { type ProfessionalFormState, saveProfessional } from "./actions";

export interface ProfessionalRow {
  id: string;
  name: string;
  council: string;
  registration: string;
  state: string;
  specialty: string | null;
  active: boolean;
  updated_at: string;
  can_manage: boolean;
}

const COUNCILS = ["CRM", "CRO", "CRMV", "COREN", "CRF", "RMS"];
const STATES = [
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA", "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ",
  "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO",
];

/** Cadastro (sem row) ou edição de um profissional. */
export function ProfessionalForm({ row }: { row?: ProfessionalRow }) {
  const [state, action, pending] = useActionState<ProfessionalFormState, FormData>(saveProfessional, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done && !row) form.current?.reset();
  }, [state, row]);
  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      {row && <input type="hidden" name="id" value={row.id} />}
      <div className={styles.inline}>
        <label>
          Nome
          <input name="name" required minLength={3} maxLength={150} size={30} defaultValue={row?.name} />
        </label>
        <label>
          Conselho
          <select name="council" required defaultValue={row?.council ?? "CRM"}>
            {COUNCILS.map((council) => (
              <option key={council}>{council}</option>
            ))}
          </select>
        </label>
        <label>
          Número
          <input name="registration" required maxLength={20} size={10} defaultValue={row?.registration} />
        </label>
        <label>
          UF
          <select name="state" required defaultValue={row?.state ?? ""}>
            <option value="" disabled>
              —
            </option>
            {STATES.map((uf) => (
              <option key={uf}>{uf}</option>
            ))}
          </select>
        </label>
        <label>
          Especialidade (opcional)
          <input name="specialty" maxLength={100} size={18} defaultValue={row?.specialty ?? ""} />
        </label>
        {row && (
          <label>
            Situação
            <select name="active" defaultValue={row.active ? "true" : "false"}>
              <option value="true">Ativo</option>
              <option value="false">Inativo</option>
            </select>
          </label>
        )}
        <button type="submit" disabled={pending}>
          {row ? "Salvar" : "Cadastrar"}
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.done && <p className={styles.success}>{row ? "Profissional salvo." : "Profissional cadastrado."}</p>}
    </form>
  );
}
