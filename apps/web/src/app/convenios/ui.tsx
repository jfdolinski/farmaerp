"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { cancelInvoice, closeInvoice, InvoiceState, payInvoice, setClosingDay } from "./actions";
import styles from "../terminais/page.module.css";

function Saved({ state }: { state: InvoiceState }) {
  return (
    <>
      {state.done && <p className={styles.success}>Salvo.</p>}
      <ErrorNotice error={state.error} />
    </>
  );
}

export function ClosingDayForm({ agreementId, day }: { agreementId: string; day: number }) {
  const [state, action, pending] = useActionState<InvoiceState, FormData>(setClosingDay, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="agreementId" value={agreementId} />
      <div className={styles.inline}>
        <label>
          Dia de fechamento
          <input name="day" inputMode="numeric" defaultValue={day} required size={4} maxLength={2} />
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
      </div>
      <p className={styles.hint}>De 1 a 28. A prévia sugere fechar no último dia de fechamento que já passou.</p>
      <Saved state={state} />
    </form>
  );
}

export function CloseInvoiceForm({ agreementId, until, disabled }: { agreementId: string; until: string; disabled: boolean }) {
  const [state, action, pending] = useActionState<InvoiceState, FormData>(closeInvoice, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="agreementId" value={agreementId} />
      <input type="hidden" name="until" value={until} />
      <div className={styles.inline}>
        <button type="submit" disabled={pending || disabled}>
          Fechar a fatura
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function PayInvoiceForm({ invoiceId, today }: { invoiceId: string; today: string }) {
  const [state, action, pending] = useActionState<InvoiceState, FormData>(payInvoice, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="invoiceId" value={invoiceId} />
      <div className={styles.inline}>
        <label>
          Pago em
          <input type="date" name="paidOn" defaultValue={today} max={today} required />
        </label>
        <label>
          Observação
          <input name="note" maxLength={500} placeholder="Opcional (ex.: TED, boleto)" size={30} />
        </label>
        <button type="submit" disabled={pending}>
          Registrar pagamento
        </button>
      </div>
      <Saved state={state} />
    </form>
  );
}

export function CancelInvoiceForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState<InvoiceState, FormData>(cancelInvoice, {});
  return (
    <details className={styles.reason}>
      <summary>Cancelar esta fatura</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="invoiceId" value={invoiceId} />
        <label>
          Motivo
          <input name="reason" maxLength={500} required size={40} />
        </label>
        <button type="submit" disabled={pending}>
          Cancelar fatura
        </button>
      </form>
      <p className={styles.hint}>
        Só a última fatura fechada do convênio pode ser cancelada. As vendas dela voltam para o próximo fechamento.
      </p>
      <Saved state={state} />
    </details>
  );
}

export function PrintButton() {
  return (
    <button type="button" onClick={() => window.print()}>
      Imprimir
    </button>
  );
}
