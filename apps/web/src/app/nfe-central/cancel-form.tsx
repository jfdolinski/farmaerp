"use client";

import { useActionState, useEffect, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { remaining } from "../notas-fiscais/ui";
import styles from "../terminais/page.module.css";
import { cancelCentralNfe, type CentralCancelState } from "./actions";

/**
 * Cancelar a NF-e emitida pela central (devolução ou transferência): motivo de 15 a 255 letras, até
 * 24 horas da autorização. Só a nota é cancelada; a operação fica e pode ganhar uma NF-e nova.
 */
export function CentralCancelForm({ id, until, next }: { id: string; until: string; next: string }) {
  const [state, action, pending] = useActionState<CentralCancelState, FormData>(cancelCentralNfe, {});
  const [reason, setReason] = useState("");
  // A hora só vem do navegador (o servidor não calcula o prazo, para a página não mudar ao abrir).
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, 30_000);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, []);
  if (state.done) return <p className={styles.success}>NF-e cancelada na Sefaz. A operação continua feita: emita uma NF-e nova, se precisar.</p>;
  if (now !== null && new Date(until).getTime() <= now) {
    return <p className={styles.hint}>O prazo de 24 horas para cancelar esta NF-e acabou.</p>;
  }
  const length = reason.trim().length;
  return (
    <details>
      <summary>Cancelar a NF-e</summary>
      <form action={action} className={styles.stack}>
        <input type="hidden" name="id" value={id} />
        <input type="hidden" name="next" value={next} />
        <label>
          Motivo do cancelamento (vai para a Sefaz)
          <textarea
            name="reason"
            required
            minLength={15}
            maxLength={255}
            rows={2}
            cols={40}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
          />
        </label>
        <p className={styles.hint}>
          {length}/255 letras (mínimo 15)
          {now !== null && (
            <>
              {" "}
              · prazo restante: <strong>{remaining(until, now)}</strong>
            </>
          )}
        </p>
        <label className={styles.check}>
          <input type="checkbox" name="confirm" required />
          Cancelar só a nota: a operação e o estoque ficam como estão.
        </label>
        <div className={styles.inline}>
          <button type="submit" disabled={pending || length < 15}>
            {pending ? "Cancelando..." : "Cancelar a NF-e"}
          </button>
        </div>
        <ErrorNotice error={state.error} />
        {state.uncertain && (
          <p className={styles.warning}>
            Sem resposta a tempo: o cancelamento pode ter sido registrado na Sefaz. Atualize a página antes de tentar de novo.
          </p>
        )}
      </form>
    </details>
  );
}
