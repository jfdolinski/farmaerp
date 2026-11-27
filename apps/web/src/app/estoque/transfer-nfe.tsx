"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { emitTransferNfe, TransferNfeState } from "./actions";

/** NF-e da transferência que veio com a movimentação (a mais recente). */
export interface TransferInfo {
  id: string;
  can_issue_nfe: boolean;
  nfe: {
    id: string;
    series: number;
    number: number;
    status: "pending" | "authorized" | "rejected";
    status_code: string | null;
    reason: string | null;
    authorized_at: string | null;
  } | null;
}

/** Situação da NF-e de transferência, os arquivos e o botão de emitir ou transmitir de novo. */
export function TransferNfeCell({ transfer, reversed }: { transfer: TransferInfo; reversed: boolean }) {
  const [state, action, pending] = useActionState<TransferNfeState, FormData>(emitTransferNfe, {});
  const nfe = transfer.nfe;
  const label = !nfe ? "Emitir NF-e" : nfe.status === "pending" ? "Transmitir de novo" : "Emitir de novo";
  return (
    <div className={styles.stack}>
      {!nfe && <span className={styles.hint}>Sem NF-e</span>}
      {nfe?.status === "authorized" && (
        <>
          <span className={styles.success}>
            Autorizada · nº {nfe.number} série {nfe.series}
          </span>
          <span>
            <a href={`/nfe-central/${nfe.id}/danfe`}>DANFE</a> · <a href={`/nfe-central/${nfe.id}/xml`}>XML</a>
          </span>
        </>
      )}
      {nfe?.status === "pending" && (
        <span className={styles.warning}>Pendente: a Sefaz ainda não respondeu (nº {nfe.number}).</span>
      )}
      {nfe?.status === "rejected" && (
        <span className={styles.warning}>
          Recusada pela Sefaz{nfe.status_code && ` (${nfe.status_code})`}: {nfe.reason ?? "sem motivo informado"}
        </span>
      )}
      {transfer.can_issue_nfe && !reversed && nfe?.status !== "authorized" && (
        <form action={action}>
          <input type="hidden" name="transferId" value={transfer.id} />
          <button type="submit" disabled={pending}>
            {pending ? "Transmitindo..." : label}
          </button>
        </form>
      )}
      <ErrorNotice error={state.error} />
      {state.notice && (
        <small className={styles.hint} role="status">
          {state.notice}
        </small>
      )}
    </div>
  );
}
