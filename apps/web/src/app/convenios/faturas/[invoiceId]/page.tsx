import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../../app-header";
import { ErrorNotice } from "../../../error-notice";
import { dayText, InvoiceDetail, itemLabel, momentText, moneyText, STATUS, todayText } from "../../format";
import { CancelInvoiceForm, PayInvoiceForm, PrintButton } from "../../ui";
import styles from "../../../terminais/page.module.css";
import print from "../../print.module.css";

export const metadata: Metadata = { title: "Fatura do convênio · FarmaERP" };

type Params = Promise<{ invoiceId: string }>;

export default function InvoicePage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando fatura...</p>}>
        <InvoiceContent params={params} />
      </Suspense>
    </main>
  );
}

async function InvoiceContent({ params }: { params: Params }) {
  const { invoiceId } = await params;
  const path = `/convenios/faturas/${invoiceId}`;
  const user = await requireUser(path);

  if (!can(user, "agreements.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Fatura do convênio</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as faturas dos convênios.</p>
        </section>
      </>
    );
  }

  const invoice = await apiFetch<InvoiceDetail>(`/admin/agreement-invoices/${encodeURIComponent(invoiceId)}`);
  if (!invoice.ok) {
    redirectIfNeeded(invoice.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Fatura do convênio</h1>
        <ErrorNotice error={invoice.error} />
      </>
    );
  }
  const data = invoice.data;

  return (
    <>
      <div className={print.noPrint}>
        <AppHeader user={user} />
      </div>
      <div className={styles.header}>
        <h1>Fatura · {data.agreement_name}</h1>
        <span className={`${styles.inline} ${print.noPrint}`}>
          <PrintButton />
          <a href={`/convenios/faturas/${data.id}/csv`} download>
            Baixar CSV
          </a>
          <Link href={`/convenios/${data.agreement_id}`}>Voltar para as faturas</Link>
        </span>
      </div>
      <section className={styles.card}>
        <p>
          {data.agreement_cnpj && <>CNPJ {data.agreement_cnpj} · </>}
          Período de {dayText(data.period_start)} a {dayText(data.period_end)}
        </p>
        <p>
          Situação: <strong>{STATUS[data.status] ?? data.status}</strong>
          {data.paid_on && <> em {dayText(data.paid_on)}</>}
          {data.paid_note && <> ({data.paid_note})</>}
          {data.cancel_reason && <> · Motivo: {data.cancel_reason}</>}
        </p>
        <p className={styles.hint}>
          Fechada por {data.closed_by_name} em {momentText(data.created_at)}.
        </p>
        <p>
          <strong>Total: R$ {moneyText(data.total)}</strong>
        </p>
      </section>
      <section className={styles.card}>
        <h2>Por cliente</h2>
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
              {data.customers.map((row) => (
                <tr key={`${row.customer_name}|${row.registration}`}>
                  <td>{row.customer_name ?? "Sem cliente"}</td>
                  <td>{row.registration}</td>
                  <td>R$ {moneyText(row.total)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      <section className={styles.card}>
        <h2>Lançamentos</h2>
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Data</th>
                <th>Cliente</th>
                <th>Matrícula</th>
                <th>Lançamento</th>
                <th>Valor</th>
              </tr>
            </thead>
            <tbody>
              {data.items.map((item, index) => (
                <tr key={index}>
                  <td>{momentText(item.occurred_at)}</td>
                  <td>{item.customer_name}</td>
                  <td>{item.registration}</td>
                  <td>{itemLabel(item)}</td>
                  <td>R$ {moneyText(item.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className={styles.hint}>Devoluções aparecem com valor negativo: abatem o total da fatura.</p>
      </section>
      {data.status === "closed" && (
        <section className={`${styles.card} ${print.noPrint}`}>
          <h2>Pagamento</h2>
          <PayInvoiceForm invoiceId={data.id} today={todayText()} />
          <CancelInvoiceForm invoiceId={data.id} />
        </section>
      )}
    </>
  );
}
