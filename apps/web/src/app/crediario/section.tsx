import { apiFetch } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import { brl, dateTimeText, PAYMENT_LABELS } from "../vendas/labels";
import { DependentToggle, LimitForm, OpenCreditForm, Policy, StatusForm, Terms, TermsForm } from "./ui";
import styles from "../terminais/page.module.css";

interface Summary {
  principal_open: number;
  charges_open: number;
  total_open: number;
  available: number;
  overdue_principal: number;
  oldest_due: string | null;
  overdue_days: number;
  blocked_by_overdue: boolean;
}

interface CreditDetail {
  account: null | {
    id: string;
    home_branch_name: string;
    credit_limit: number;
    status: "active" | "blocked";
    terms: Terms;
  };
  can_open?: boolean;
  suggested_limits?: { branch_id: string; branch_name: string; suggested_limit: number }[];
  can_manage?: boolean;
  policy?: Policy;
  summary?: Summary;
  suggested_limit?: number;
  installments?: {
    id: string;
    sale_id: string;
    sale_code: string;
    sold_at: string;
    branch_name: string;
    dependent_name: string | null;
    number: number;
    count: number;
    due_date: string;
    amount: number;
    paid_principal: number;
    paid_charges: number;
    position: { fee: number; interest: number; principal: number } | null;
  }[];
  payments?: {
    id: string;
    received_at: string;
    branch_name: string;
    received_by_name: string;
    method: string;
    amount: number;
    excess: number;
    fee: number;
    interest: number;
    principal: number;
  }[];
  events?: {
    kind: string;
    old_limit: number | null;
    new_limit: number | null;
    suggested_limit: number | null;
    detail: Partial<Terms>;
    reason: string | null;
    changed_by_name: string;
    created_at: string;
  }[];
  dependents?: { id: string; name: string; relationship: string; credit_allowed: boolean }[];
}

/** Data (AAAA-MM-DD) no formato do Brasil, sem passar por fuso. */
export const dayText = (value: string) => value.split("-").reverse().join("/");

export function termsText(terms: Pick<Terms, "due_mode" | "closing_day" | "due_day" | "interval_days">) {
  return terms.due_mode === "closing"
    ? `fatura mensal: fecha no dia ${terms.closing_day} e vence no dia ${terms.due_day}`
    : `dias corridos: a cada ${terms.interval_days} dias da compra`;
}

function eventText(event: NonNullable<CreditDetail["events"]>[number]) {
  switch (event.kind) {
    case "opened":
      return `Crediário aberto com limite de ${brl(event.new_limit)} (sugerido ${brl(event.suggested_limit)})`;
    case "limit":
      return `Limite de ${brl(event.old_limit)} para ${brl(event.new_limit)} (sugerido ${brl(event.suggested_limit)})`;
    case "blocked":
      return "Bloqueado para novas compras";
    case "unblocked":
      return "Liberado para novas compras";
    case "terms":
      return `Vencimentos: ${event.detail.own ? termsText(event.detail as Terms) : "padrão da filial"}`;
    default:
      return event.kind;
  }
}

/** Crediário na ficha do cliente. Some para quem não vê o crediário. */
export async function CreditSection({ customerId }: { customerId: string }) {
  const result = await apiFetch<CreditDetail>(`/admin/credit/customers/${encodeURIComponent(customerId)}`);
  if (!result.ok) {
    return (
      <section className={styles.card}>
        <h2>Crediário</h2>
        <ErrorNotice error={result.error} />
      </section>
    );
  }
  const credit = result.data;
  const account = credit.account;
  if (!account) {
    if (!credit.can_open) return null;
    return (
      <section className={styles.card}>
        <h2>Crediário</h2>
        <p className={styles.hint}>Este cliente ainda não tem crediário.</p>
        <OpenCreditForm customerId={customerId} branches={credit.suggested_limits ?? []} />
      </section>
    );
  }
  const summary = credit.summary!;
  const canManage = Boolean(credit.can_manage);
  const installments = credit.installments ?? [];
  const open = installments.filter((i) => i.position);
  const paid = installments.filter((i) => !i.position);

  return (
    <section className={styles.card}>
      <h2>Crediário</h2>
      <p>
        {account.status === "blocked" ? (
          <strong className={styles.warning}>Bloqueado para novas compras. </strong>
        ) : summary.blocked_by_overdue ? (
          <strong className={styles.warning}>
            Compras bloqueadas: parcela vencida há {summary.overdue_days} dias (limite da filial:{" "}
            {credit.policy?.block_after_days} dias).{" "}
          </strong>
        ) : null}
        Limite {brl(account.credit_limit)} · em aberto {brl(summary.principal_open)}
        {summary.charges_open > 0 && <> + encargos {brl(summary.charges_open)}</>} · disponível {brl(summary.available)}
        {summary.overdue_principal > 0 && (
          <span className={styles.warning}>
            {" "}
            · vencido {brl(summary.overdue_principal)} desde {dayText(summary.oldest_due!)}
          </span>
        )}
      </p>
      <p className={styles.hint}>
        Filial da conta: {account.home_branch_name} · vencimentos {account.terms.own ? "próprios" : "da filial"} (
        {termsText(account.terms)}) · multa {credit.policy?.late_fee_percent}% e juros de{" "}
        {credit.policy?.monthly_interest_percent}% ao mês.
      </p>
      {canManage && (
        <>
          <LimitForm accountId={account.id} customerId={customerId} current={account.credit_limit} suggested={credit.suggested_limit ?? 0} />
          <StatusForm accountId={account.id} customerId={customerId} status={account.status} />
          <TermsForm accountId={account.id} customerId={customerId} terms={account.terms} />
        </>
      )}

      <h3>Parcelas em aberto</h3>
      {open.length === 0 ? (
        <p className={styles.hint}>Nada em aberto.</p>
      ) : (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Vencimento</th>
                <th>Compra</th>
                <th>Parcela</th>
                <th>Valor</th>
                <th>Em aberto</th>
                <th>Multa e juros hoje</th>
              </tr>
            </thead>
            <tbody>
              {open.map((item) => (
                <tr key={item.id}>
                  <td>{dayText(item.due_date)}</td>
                  <td>
                    <a href={`/vendas/${item.sale_id}`}>{item.sale_code}</a>
                    <small className={styles.hint}>
                      {" "}
                      · {item.branch_name}
                      {item.dependent_name ? ` · ${item.dependent_name}` : ""}
                    </small>
                  </td>
                  <td>
                    {item.number} de {item.count}
                  </td>
                  <td>{brl(item.amount)}</td>
                  <td>{brl(item.position!.principal)}</td>
                  <td>{item.position!.fee + item.position!.interest > 0 ? brl(item.position!.fee + item.position!.interest) : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <details className={styles.reason}>
        <summary>Recebimentos ({credit.payments?.length ?? 0})</summary>
        {(credit.payments ?? []).length === 0 && <p className={styles.hint}>Nenhum recebimento.</p>}
        {(credit.payments ?? []).length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Loja e quem recebeu</th>
                  <th>Forma</th>
                  <th>Valor</th>
                  <th>Parcelas</th>
                  <th>Multa e juros</th>
                </tr>
              </thead>
              <tbody>
                {credit.payments!.map((payment) => (
                  <tr key={payment.id}>
                    <td>{dateTimeText(payment.received_at)}</td>
                    <td>
                      {payment.branch_name}
                      <small className={styles.hint}> · {payment.received_by_name}</small>
                    </td>
                    <td>{PAYMENT_LABELS[payment.method] ?? payment.method}</td>
                    <td>
                      {brl(payment.amount)}
                      {payment.excess > 0 && <small className={styles.warning}> · {brl(payment.excess)} a mais</small>}
                    </td>
                    <td>{brl(payment.principal)}</td>
                    <td>{brl(payment.fee + payment.interest)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </details>

      {paid.length > 0 && (
        <details className={styles.reason}>
          <summary>Parcelas pagas ({paid.length})</summary>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Vencimento</th>
                  <th>Compra</th>
                  <th>Parcela</th>
                  <th>Valor</th>
                  <th>Encargos pagos</th>
                </tr>
              </thead>
              <tbody>
                {paid.map((item) => (
                  <tr key={item.id}>
                    <td>{dayText(item.due_date)}</td>
                    <td>
                      <a href={`/vendas/${item.sale_id}`}>{item.sale_code}</a>
                    </td>
                    <td>
                      {item.number} de {item.count}
                    </td>
                    <td>{brl(item.amount)}</td>
                    <td>{brl(item.paid_charges)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
      )}

      {(credit.dependents ?? []).length > 0 && (
        <>
          <h3>Dependentes no crediário</h3>
          {credit.dependents!.map((dependent) => (
            <DependentToggle key={dependent.id} customerId={customerId} dependent={dependent} canManage={canManage} />
          ))}
        </>
      )}

      <details className={styles.reason}>
        <summary>Histórico da conta</summary>
        <ul>
          {(credit.events ?? []).map((event, index) => (
            <li key={index}>
              {dateTimeText(event.created_at)} · {event.changed_by_name}: {eventText(event)}
              {event.reason && <small className={styles.hint}> · {event.reason}</small>}
            </li>
          ))}
        </ul>
      </details>
    </section>
  );
}
