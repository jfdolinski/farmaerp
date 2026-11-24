import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { brl, dateTimeText, PAYMENT_LABELS } from "../../vendas/labels";
import { differenceText } from "../labels";

export const metadata: Metadata = { title: "Caixa · FarmaERP" };

type Params = Promise<{ id: string }>;

interface SessionDetail {
  id: string;
  branch_name: string;
  terminal_name: string;
  status: "open" | "closed";
  opened_by_name: string;
  opened_at: string;
  opening_float: number;
  closed_by_name: string | null;
  closed_at: string | null;
  closing_note: string | null;
  sale_count: number;
  sales_total: number;
  counts: { method: string; counted: number | null; expected: number; difference: number | null }[];
  movements: {
    id: string;
    kind: "withdrawal" | "supply";
    amount: number;
    reason: string;
    moved_at: string;
    operator_name: string;
    released_by_name: string | null;
  }[];
  alerts: { kind: string; movement_id: string | null; detail: Record<string, unknown> }[];
}

function alertText(alert: SessionDetail["alerts"][number]): string {
  if (alert.kind === "closing_difference") {
    const order = ["cash", "credit_card", "debit_card", "pix"];
    const entries = Object.entries(alert.detail).sort(([a], [b]) => order.indexOf(a) - order.indexOf(b));
    const parts = entries.map(([method, value]) => {
      const text = differenceText(value as number);
      return `${PAYMENT_LABELS[method] ?? method}: ${text.charAt(0).toLowerCase()}${text.slice(1)}`;
    });
    return `Diferença no fechamento (${parts.join("; ")})`;
  }
  if (alert.kind === "return_payout") {
    const problems: Record<string, string> = {
      already_paid: "o documento já tinha sido pago",
      not_cash: "o documento não é de devolução em dinheiro",
      amount: "o valor é diferente do documento",
      other_branch: "o documento é de outra loja",
    };
    return `Sangria de devolução ${alert.detail.return_code}: ${problems[alert.detail.problem as string] ?? alert.detail.problem}`;
  }
  if (alert.kind === "withdrawal_above_limit") {
    const limit = alert.detail.operator_limit as number;
    return alert.detail.released_by
      ? `Sangria de ${brl(alert.detail.amount as number)} liberada por quem não tinha limite (${brl(alert.detail.releaser_limit as number)})`
      : `Sangria de ${brl(alert.detail.amount as number)} acima do limite do operador (${brl(limit)}), sem liberação`;
  }
  return alert.kind;
}

export default function CashSessionPage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando o caixa...</p>}>
        <CashSessionContent params={params} />
      </Suspense>
    </main>
  );
}

async function CashSessionContent({ params }: { params: Params }) {
  const { id } = await params;
  const user = await requireUser(`/caixas/${id}`);
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Caixa</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os caixas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<SessionDetail>(`/admin/cash-sessions/${encodeURIComponent(id)}`);
  if (!result.ok) redirectIfNeeded(result.error, `/caixas/${id}`);
  return (
    <>
      <AppHeader user={user} />
      <p>
        <Link href="/caixas">Voltar para os caixas</Link>
      </p>
      {!result.ok && <ErrorNotice error={result.error} />}
      {result.ok && <SessionView session={result.data} />}
    </>
  );
}

function SessionView({ session }: { session: SessionDetail }) {
  const closed = session.status === "closed";
  return (
    <>
      <h1>
        Caixa {session.terminal_name} · {dateTimeText(session.opened_at)}
      </h1>
      <section className={styles.card}>
        <p>
          {session.branch_name} · Aberto por {session.opened_by_name} com fundo de troco {brl(session.opening_float)}
        </p>
        <p>
          {closed
            ? `Fechado em ${dateTimeText(session.closed_at!)} por ${session.closed_by_name}`
            : "Aberto. O esperado abaixo é o de agora."}
        </p>
        {session.closing_note && <p>Observação do fechamento: {session.closing_note}</p>}
        <p>
          {session.sale_count === 1 ? "1 venda" : `${session.sale_count} vendas`} · {brl(session.sales_total)}
        </p>
      </section>

      {session.alerts.length > 0 && (
        <section className={styles.card}>
          <h2>Alertas</h2>
          <ul className={styles.bullets}>
            {session.alerts.map((alert, index) => (
              <li key={index}>{alertText(alert)}</li>
            ))}
          </ul>
        </section>
      )}

      <section className={styles.card}>
        <h2>Conferência</h2>
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Forma</th>
                <th>Esperado</th>
                <th>Contado</th>
                <th>Diferença</th>
              </tr>
            </thead>
            <tbody>
              {session.counts.map((count) => (
                <tr key={count.method}>
                  <td>{PAYMENT_LABELS[count.method] ?? count.method}</td>
                  <td>{brl(count.expected)}</td>
                  <td>{count.counted === null ? "—" : brl(count.counted)}</td>
                  <td className={count.difference ? styles.warning : undefined}>
                    {count.difference === null ? "—" : differenceText(count.difference)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className={styles.hint}>
          Dinheiro esperado: fundo de troco + vendas em dinheiro (menos o troco) + suprimentos − sangrias. Convênio não
          passa pelo caixa.
        </p>
      </section>

      <section className={styles.card}>
        <h2>Sangrias e suprimentos</h2>
        {session.movements.length === 0 ? (
          <p className={styles.hint}>Nenhum movimento no turno.</p>
        ) : (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Tipo</th>
                  <th>Valor</th>
                  <th>Motivo</th>
                  <th>Quem fez</th>
                </tr>
              </thead>
              <tbody>
                {session.movements.map((movement) => (
                  <tr key={movement.id}>
                    <td>{dateTimeText(movement.moved_at)}</td>
                    <td>{movement.kind === "withdrawal" ? "Sangria" : "Suprimento"}</td>
                    <td>{brl(movement.amount)}</td>
                    <td>{movement.reason}</td>
                    <td>
                      {movement.operator_name}
                      {movement.released_by_name && (
                        <small className={styles.hint}>Liberada por {movement.released_by_name}</small>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
