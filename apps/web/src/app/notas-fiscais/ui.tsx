"use client";

import { useActionState, useEffect, useState } from "react";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import {
  cancelDocument,
  consultDocument,
  dismissAlert,
  type FiscalFormState,
  resendDocument,
  voidRange,
} from "./actions";

const STATUS_AFTER: Record<string, string> = {
  authorized: "A nota está autorizada.",
  canceled: "A nota está cancelada na Sefaz.",
  not_found: "A Sefaz ainda não tem esta nota.",
  rejected: "A Sefaz recusou a nota de novo. Veja o motivo na lista.",
  unavailable: "A Sefaz não respondeu. Tente de novo em alguns minutos.",
  pending: "A nota continua pendente.",
  contingency: "A nota continua em contingência.",
};

function Uncertain({ state }: { state: FiscalFormState }) {
  if (!state.uncertain) return null;
  return (
    <p className={styles.warning}>
      Sem resposta a tempo: a operação pode ter sido feita na Sefaz. Clique em Consultar para ver a situação real antes
      de tentar de novo.
    </p>
  );
}

/** Consultar e (quando pode) reenviar. */
export function DocumentActions({ id, canResend }: { id: string; canResend: boolean }) {
  const [consulted, consult, consulting] = useActionState<FiscalFormState, FormData>(consultDocument, {});
  const [resent, resend, resending] = useActionState<FiscalFormState, FormData>(resendDocument, {});
  const last = resent.result ?? consulted.result;
  return (
    <div className={styles.stack}>
      <div className={styles.inline}>
        <form action={consult}>
          <input type="hidden" name="id" value={id} />
          <button type="submit" disabled={consulting || resending}>
            {consulting ? "Consultando..." : "Consultar na Sefaz"}
          </button>
        </form>
        {canResend && (
          <form action={resend}>
            <input type="hidden" name="id" value={id} />
            <button type="submit" disabled={consulting || resending}>
              {resending ? "Reenviando..." : "Reenviar"}
            </button>
          </form>
        )}
      </div>
      {last && <p className={styles.success}>{STATUS_AFTER[String(last.status)] ?? `Situação: ${String(last.status)}`}</p>}
      <ErrorNotice error={consulted.error ?? resent.error} />
      <Uncertain state={consulted.error ? consulted : resent} />
    </div>
  );
}

function remaining(until: string, now: number): string {
  const seconds = Math.max(0, Math.floor((new Date(until).getTime() - now) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

const CASH_MESSAGES: Record<string, string> = {
  same_session: "O dinheiro sai do esperado do mesmo turno: devolva ao cliente pela gaveta.",
  open_session: "O turno da venda já fechou: a devolução ao cliente foi registrada como sangria no turno aberto do caixa.",
  no_session:
    "O turno da venda já fechou e o caixa não tem turno aberto: nada foi registrado no caixa. Devolva o dinheiro e registre a saída à mão.",
};

/** Cancelamento: motivo de 15 a 255 letras, até o fim do prazo (NFC-e 30 minutos, NF-e 24 horas). */
export function CancelForm({ id, until, model }: { id: string; until: string; model: string }) {
  const label = model === "55" ? "NF-e" : "NFC-e";
  const limit = model === "55" ? "24 horas" : "30 minutos";
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(cancelDocument, {});
  const [reason, setReason] = useState("");
  // A hora só vem do navegador (o servidor não calcula o prazo, para a página não mudar ao abrir).
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, []);
  const expired = now !== null && new Date(until).getTime() <= now;
  const length = reason.trim().length;
  if (state.result) {
    const cash = String(state.result.cash_refund ?? "none");
    return (
      <div className={styles.stack}>
        {state.result.sale_kept ? (
          <p className={styles.warning}>
            {label} cancelada na Sefaz, mas a venda não foi desfeita ({String(state.result.sale_kept)}): acerte pela devolução.
          </p>
        ) : (
          <p className={styles.success}>{label} cancelada na Sefaz e venda desfeita (estoque de volta, pagamentos estornados).</p>
        )}
        {CASH_MESSAGES[cash] && <p className={cash === "no_session" ? styles.warning : styles.hint}>{CASH_MESSAGES[cash]}</p>}
        <p className={styles.hint}>Cartão e PIX: faça o estorno ao cliente na maquininha ou no banco.</p>
      </div>
    );
  }
  if (expired) return <p className={styles.hint}>O prazo de {limit} para cancelar acabou. Para desfazer, use a devolução.</p>;
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="id" value={id} />
      <label>
        Motivo do cancelamento (vai para a Sefaz)
        <textarea
          name="reason"
          required
          minLength={15}
          maxLength={255}
          rows={2}
          cols={50}
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
        Cancelar a nota e desfazer a venda (estoque, pagamentos, cashback e crediário).
      </label>
      <div className={styles.inline}>
        <button type="submit" disabled={pending || length < 15}>
          {pending ? "Cancelando..." : `Cancelar a ${label} e a venda`}
        </button>
      </div>
      <ErrorNotice error={state.error} />
      <Uncertain state={state} />
    </form>
  );
}

export function DismissButton({ id }: { id: string }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(dismissAlert, {});
  return (
    <form action={action}>
      <input type="hidden" name="id" value={id} />
      <button type="submit" disabled={pending}>
        Já vi
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

/** Inutilização de uma faixa sugerida (dá para diminuir a faixa). */
export function VoidForm({
  branchId,
  series,
  first,
  last,
  safe,
}: {
  branchId: string;
  series: number;
  first: number;
  last: number;
  safe: boolean;
}) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(voidRange, {});
  const [reason, setReason] = useState("");
  if (state.result) {
    return <p className={styles.success}>Faixa inutilizada na Sefaz (protocolo {String(state.result.protocol)}).</p>;
  }
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="branchId" value={branchId} />
      <input type="hidden" name="series" value={series} />
      <div className={styles.inline}>
        <label>
          De
          <input type="number" name="first" defaultValue={first} min={first} max={last} required />
        </label>
        <label>
          Até
          <input type="number" name="last" defaultValue={last} min={first} max={last} required />
        </label>
        <label>
          Motivo (vai para a Sefaz)
          <input
            name="reason"
            required
            minLength={15}
            maxLength={255}
            size={36}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
          />
        </label>
      </div>
      {!safe && (
        <label className={styles.check}>
          <input type="checkbox" name="confirm" required />
          O caixa ainda tem itens na fila para a central: confirmo que estes números não foram usados.
        </label>
      )}
      <div className={styles.inline}>
        <button type="submit" disabled={pending || reason.trim().length < 15}>
          {pending ? "Inutilizando..." : "Inutilizar"}
        </button>
      </div>
      <ErrorNotice error={state.error} />
      <Uncertain state={state} />
    </form>
  );
}
