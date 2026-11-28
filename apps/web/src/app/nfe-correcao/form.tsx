"use client";

import { useActionState, useState } from "react";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { sendCorrection, type CorrectionState } from "./actions";

/** Como a API manda para a Sefaz: numa linha, sem espaços repetidos. */
const oneLine = (value: string) => value.replace(/\s+/g, " ").trim();

/**
 * Nova carta de correção: substitui as anteriores, então começa com o texto da última para a pessoa
 * acrescentar o que falta. De 15 a 1000 caracteres.
 */
export function CorrectionForm({ kind, id, last }: { kind: "sale" | "central"; id: string; last: string | null }) {
  const [state, action, pending] = useActionState<CorrectionState, FormData>(sendCorrection, {});
  const [text, setText] = useState(last ?? "");
  const length = oneLine(text).length;
  const unchanged = last !== null && oneLine(text) === last;
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="id" value={id} />
      <label>
        Correção (vai para a Sefaz como está escrita)
        <textarea
          name="text"
          required
          minLength={15}
          maxLength={1000}
          rows={6}
          value={text}
          onChange={(event) => setText(event.target.value)}
        />
      </label>
      <p className={styles.hint}>
        {length}/1000 caracteres (mínimo 15). A carta nova substitui as anteriores: escreva todas as correções desta nota,
        não só a nova. Quebras de linha viram espaço.
      </p>
      <p className={styles.hint}>
        A carta não corrige valores, impostos, quantidades, a data de emissão ou de saída, nem troca o remetente ou o
        destinatário.
      </p>
      <label className={styles.check}>
        <input type="checkbox" name="confirm" required />
        Conferi o texto: a carta registrada na Sefaz não pode ser desfeita.
      </label>
      <div className={styles.inline}>
        <button type="submit" disabled={pending || length < 15 || length > 1000 || unchanged}>
          {pending ? "Enviando..." : "Enviar a carta de correção"}
        </button>
      </div>
      {unchanged && <p className={styles.hint}>O texto é igual ao da última carta: acrescente a correção nova.</p>}
      {state.sequence !== undefined && !state.error && (
        <p className={styles.success} role="status">
          Carta {state.sequence} registrada na Sefaz.
        </p>
      )}
      <ErrorNotice error={state.error} />
      {state.uncertain && (
        <p className={styles.warning}>
          Sem resposta a tempo: a carta pode ter sido registrada na Sefaz. Atualize a página antes de enviar de novo.
        </p>
      )}
    </form>
  );
}
