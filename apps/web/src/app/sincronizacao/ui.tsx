"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { getError } from "@farmaerp/error-catalog";
import { resolveConflict, ResolveState, retryConflict, RetryState } from "./actions";
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

/** Aplica de novo o que o terminal enviou, por exemplo depois de atualizar a API. */
export function RetryForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<RetryState, FormData>(retryConflict, {});
  const refused = state.outcome?.status === "conflict" && state.outcome.code ? getError(state.outcome.code) : null;
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="id" value={id} />
      <button type="submit" disabled={pending}>
        {pending ? "Reaplicando..." : "Reaplicar"}
      </button>
      {refused && (
        <p className={styles.warning} role="status">
          A central recusou de novo: {refused.message} <small>Código {state.outcome!.code}</small>
        </p>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}
