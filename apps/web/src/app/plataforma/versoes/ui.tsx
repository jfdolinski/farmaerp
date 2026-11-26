"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../../error-notice";
import { ReleaseState, setReleaseStatus } from "./actions";
import styles from "../../terminais/page.module.css";

/** Botões da versão: liberar para a rede (só a de teste) e retirar (pede confirmação). */
export function ReleaseActions({ id, status, version }: { id: string; status: string; version: string }) {
  const [state, action, pending] = useActionState<ReleaseState, FormData>(setReleaseStatus, {});
  return (
    <form
      action={action}
      className={styles.rowForm}
      onSubmit={(event) => {
        const submitter = (event.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null;
        if (
          submitter?.value === "withdrawn" &&
          !window.confirm(`Retirar a versão ${version}? Os PDVs deixam de receber esta versão e isso não pode ser desfeito.`)
        ) {
          event.preventDefault();
        }
      }}
    >
      <input type="hidden" name="id" value={id} />
      {status === "test" && (
        <button type="submit" name="status" value="general" disabled={pending}>
          Liberar para a rede
        </button>
      )}
      <button type="submit" name="status" value="withdrawn" disabled={pending}>
        Retirar
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}
