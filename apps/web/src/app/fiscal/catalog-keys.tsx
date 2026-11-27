"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import { clearCatalogKey, type FiscalFormState, setCatalogKey } from "./actions";

export interface CatalogKeyRow {
  branch_id: string;
  branch_name: string;
  company_name: string;
  key_prefix: string | null;
  key_updated_at: string | null;
  can_manage: boolean;
}

const dateText = (value: string) => new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" });

/**
 * Chave do Catálogo de uma filial. A chave é conferida no Catálogo antes de ser guardada (cifrada);
 * a tela mostra só o começo dela.
 */
export function CatalogKeyForm({ row }: { row: CatalogKeyRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setCatalogKey, {});
  const [cleared, clear, clearing] = useActionState<FiscalFormState, FormData>(clearCatalogKey, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);
  return (
    <>
      <p className={row.key_prefix ? styles.hint : styles.warning}>
        {row.key_prefix
          ? `Chave em uso: ${row.key_prefix}…, cadastrada em ${dateText(row.key_updated_at ?? "")}. A chave completa fica guardada e não é mostrada.`
          : "Sem chave do Catálogo: esta filial não consulta o Catálogo nem recebe a tributação dele."}
      </p>
      {row.can_manage && (
        <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack} autoComplete="off">
          <input type="hidden" name="branchId" value={row.branch_id} />
          <div className={styles.inline}>
            <label>
              {row.key_prefix ? "Trocar a chave" : "Chave da filial no Catálogo"}
              <input type="password" name="key" required maxLength={210} placeholder="cat_..." autoComplete="new-password" />
            </label>
            <button type="submit" disabled={pending}>
              {pending ? "Conferindo no Catálogo..." : "Salvar chave"}
            </button>
          </div>
          <ErrorNotice error={state.error} />
          {state.done && <p className={styles.hint}>Chave conferida no Catálogo e salva.</p>}
        </form>
      )}
      {row.can_manage && row.key_prefix && (
        <form action={clear}>
          <input type="hidden" name="branchId" value={row.branch_id} />
          <button type="submit" disabled={clearing}>
            Tirar a chave
          </button>
          <ErrorNotice error={cleared.error} />
        </form>
      )}
    </>
  );
}
