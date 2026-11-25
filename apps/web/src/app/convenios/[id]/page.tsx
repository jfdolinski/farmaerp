import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { dayText, InvoiceItem, itemLabel, momentText, moneyText, STATUS, todayText } from "../format";
import { ClosingDayForm, CloseInvoiceForm } from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Faturas do convênio · FarmaERP" };

interface Preview {
  agreement_id: string;
  agreement_name: string;
  closing_day: number;
  period_start: string | null;
  period_end: string;
  items: InvoiceItem[];
  total: number;
}

interface InvoiceRow {
  id: string;
  period_start: string;
  period_end: string;
  status: string;
  total: string;
  item_count: number;
  closed_by_name: string;
  created_at: string;
  paid_on: string | null;
}

type Params = Promise<{ id: string }>;
type Search = Promise<{ ate?: string }>;

export default function AgreementInvoicesPage({ params, searchParams }: { params: Params; searchParams: Search }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando faturas...</p>}>
        <InvoicesContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function InvoicesContent({ params, searchParams }: { params: Params; searchParams: Search }) {
  const { id } = await params;
  const { ate } = await searchParams;
  const path = `/convenios/${id}`;
  const user = await requireUser(path);

  if (!can(user, "agreements.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Faturas do convênio</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as faturas dos convênios.</p>
        </section>
      </>
    );
  }

  const until = ate && /^\d{4}-\d{2}-\d{2}$/.test(ate) ? ate : "";
  const [preview, invoices] = await Promise.all([
    apiFetch<Preview>(`/admin/agreements/${encodeURIComponent(id)}/invoice-preview${until ? `?until=${until}` : ""}`),
    apiFetch<InvoiceRow[]>(`/admin/agreements/${encodeURIComponent(id)}/invoices`),
  ]);
  if (!preview.ok) redirectIfNeeded(preview.error, path);
  if (!invoices.ok) redirectIfNeeded(invoices.error, path);

  const byCustomer = new Map<string, { name: string; registration: string; total: number }>();
  if (preview.ok) {
    for (const item of preview.data.items) {
      const key = `${item.customer_name ?? ""}|${item.registration ?? ""}`;
      const entry = byCustomer.get(key) ?? { name: item.customer_name ?? "Sem cliente", registration: item.registration ?? "", total: 0 };
      entry.total = Math.round((entry.total + Number(item.amount)) * 100) / 100;
      byCustomer.set(key, entry);
    }
  }

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Faturas{preview.ok ? ` · ${preview.data.agreement_name}` : ""}</h1>
        <Link href="/convenios">Voltar para convênios</Link>
      </div>
      {!preview.ok && <ErrorNotice error={preview.error} />}
      {preview.ok && (
        <>
          <section className={styles.card}>
            <h2>Fechamento</h2>
            <ClosingDayForm agreementId={id} day={preview.data.closing_day} />
          </section>
          <section className={styles.card}>
            <h2>Próxima fatura</h2>
            <form method="get" className={styles.inline}>
              <label>
                Fechar até
                <input type="date" name="ate" defaultValue={preview.data.period_end} max={todayText()} required />
              </label>
              <button type="submit">Ver prévia</button>
            </form>
            <p className={styles.hint}>
              {preview.data.period_start
                ? `Período de ${dayText(preview.data.period_start)} a ${dayText(preview.data.period_end)}.`
                : `Primeira fatura: tudo o que foi vendido até ${dayText(preview.data.period_end)}.`}{" "}
              Entram as vendas no convênio e as devoluções dessas vendas (como abatimento) que ainda não estão em fatura.
            </p>
            {preview.data.items.length === 0 ? (
              <p className={styles.hint}>Nada para faturar até esta data.</p>
            ) : (
              <>
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Cliente</th>
                        <th>Matrícula</th>
                        <th>Total</th>
                      </tr>
                    </thead>
                    <tbody>
                      {[...byCustomer.values()].map((row) => (
                        <tr key={`${row.name}|${row.registration}`}>
                          <td>{row.name}</td>
                          <td>{row.registration}</td>
                          <td>R$ {moneyText(row.total)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <details className={styles.reason}>
                  <summary>{preview.data.items.length} lançamento(s)</summary>
                  <div className={styles.tableWrap}>
                    <table>
                      <thead>
                        <tr>
                          <th>Data</th>
                          <th>Cliente</th>
                          <th>Lançamento</th>
                          <th>Valor</th>
                        </tr>
                      </thead>
                      <tbody>
                        {preview.data.items.map((item, index) => (
                          <tr key={index}>
                            <td>{momentText(item.occurred_at)}</td>
                            <td>{item.customer_name}</td>
                            <td>{itemLabel(item)}</td>
                            <td>R$ {moneyText(item.amount)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </details>
                <p>
                  <strong>Total da fatura: R$ {moneyText(preview.data.total)}</strong>
                </p>
              </>
            )}
            <CloseInvoiceForm agreementId={id} until={preview.data.period_end} disabled={preview.data.items.length === 0} />
          </section>
        </>
      )}
      <section className={styles.card}>
        <h2>Faturas fechadas</h2>
        {!invoices.ok && <ErrorNotice error={invoices.error} />}
        {invoices.ok && invoices.data.length === 0 && <p className={styles.hint}>Nenhuma fatura ainda.</p>}
        {invoices.ok && invoices.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Período</th>
                  <th>Situação</th>
                  <th>Lançamentos</th>
                  <th>Total</th>
                  <th>Fechada por</th>
                </tr>
              </thead>
              <tbody>
                {invoices.data.map((invoice) => (
                  <tr key={invoice.id}>
                    <td>
                      <Link href={`/convenios/faturas/${invoice.id}`}>
                        {dayText(invoice.period_start)} a {dayText(invoice.period_end)}
                      </Link>
                    </td>
                    <td>
                      {STATUS[invoice.status] ?? invoice.status}
                      {invoice.paid_on && <small>em {dayText(invoice.paid_on)}</small>}
                    </td>
                    <td>{invoice.item_count}</td>
                    <td>R$ {moneyText(invoice.total)}</td>
                    <td>
                      {invoice.closed_by_name}
                      <small>{momentText(invoice.created_at)}</small>
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
