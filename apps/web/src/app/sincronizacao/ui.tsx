"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { resolveConflict, ResolveState } from "./actions";
import styles from "../terminais/page.module.css";

/** Marca o conflito como resolvido, com a explicação de quem resolveu. */
export function ResolveForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<ResolveState, FormData>(resolveConflict, {});
  return (
    <details className={styles.reason}>
      <summary>Resolver</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <label>
          O que foi feito
          <input name="note" required maxLength={500} placeholder="Ex.: PDV atualizado; o registro não precisa voltar" />
        </label>
        <button type="submit" disabled={pending}>
          Marcar como resolvido
        </button>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}
