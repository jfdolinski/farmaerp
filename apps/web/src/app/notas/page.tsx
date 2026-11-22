import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { CONFIRMATION_LABELS, dateText, moneyText, STATUS_LABELS } from "./format";
import { AwarenessList, SummaryRow, UploadForm } from "./ui";

export const metadata: Metadata = { title: "Notas de compra · FarmaERP" };

interface InvoiceListRow {
  id: string;
  branch_name: string;
  supplier_name: string;
  series: number;
  number: string;
  issued_at: string;
  invoice_total: string;
  status: string;
  environment: number;
  item_count: string;
  pending_count: string;
  source: string;
  confirmation: string;
  confirmation_required: boolean;
  cancelled_at: string | null;
}

const STATUSES = ["review", "posted", "not_postable", "cancelled"];

type SearchParams = Promise<{ situacao?: string | string[] }>;

export default function InvoicesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando notas...</p>}>
        <InvoicesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function InvoicesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/notas");
  const canManage = can(user, "purchases.manage");

  if (!can(user, "purchases.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Notas de compra</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as notas de compra.</p>
        </section>
      </>
    );
  }

  const { situacao } = await searchParams;
  const status = typeof situacao === "string" && STATUSES.includes(situacao) ? situacao : "";
  const [invoices, summaries] = await Promise.all([
    apiFetch<InvoiceListRow[]>(`/admin/purchase-invoices?status=${status}`),
    apiFetch<SummaryRow[]>("/admin/purchase-summaries"),
  ]);
  if (!invoices.ok) redirectIfNeeded(invoices.error, "/notas");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Notas de compra</h1>
        <Link href="/fornecedores">Fornecedores</Link>
      </div>
      {canManage && (
        <section className={styles.card}>
          <h2>Importar XML</h2>
          <UploadForm />
        </section>
      )}
      {!summaries.ok && <ErrorNotice error={summaries.error} />}
      {summaries.ok && summaries.data.length > 0 && (
        <section className={styles.card}>
          <h2>Aguardando ciência</h2>
          <AwarenessList rows={summaries.data} />
        </section>
      )}
      <section className={styles.card}>
        <form action="/notas" className={styles.inline}>
          <label>
            Situação
            <select name="situacao" defaultValue={status}>
              <option value="">Todas</option>
              <option value="review">Em conferência</option>
              <option value="posted">Lançada no estoque</option>
              <option value="not_postable">Não vai para o estoque</option>
              <option value="cancelled">Cancelada pelo emitente</option>
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!invoices.ok && <ErrorNotice error={invoices.error} />}
        {invoices.ok && invoices.data.length === 0 && <p className={styles.hint}>Nenhuma nota importada ainda.</p>}
        {invoices.ok && invoices.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Nota</th>
                  <th>Fornecedor</th>
                  <th>Filial</th>
                  <th>Emissão</th>
                  <th>Valor</th>
                  <th>Situação</th>
                </tr>
              </thead>
              <tbody>
                {invoices.data.map((invoice) => (
                  <tr key={invoice.id}>
                    <td>
                      <Link href={`/notas/${invoice.id}`}>
                        {invoice.number} / {invoice.series}
                      </Link>
                      {invoice.environment === 2 && <small className={styles.warning}>Teste da Sefaz</small>}
                    </td>
                    <td>{invoice.supplier_name}</td>
                    <td>{invoice.branch_name}</td>
                    <td>{dateText(invoice.issued_at)}</td>
                    <td>{moneyText(invoice.invoice_total)}</td>
                    <td>
                      {STATUS_LABELS[invoice.status] ?? invoice.status}
                      {invoice.status === "review" && Number(invoice.pending_count) > 0 && (
                        <small className={styles.warning}>
                          {invoice.pending_count} de {invoice.item_count} itens a conferir
                        </small>
                      )}
                      {invoice.status === "review" && Number(invoice.pending_count) === 0 && (
                        <small>Todos os itens ligados</small>
                      )}
                      {invoice.cancelled_at && invoice.status === "posted" && (
                        <small className={styles.warning}>Cancelada pelo emitente depois do lançamento</small>
                      )}
                      {invoice.status !== "cancelled" && (
                        <small className={invoice.confirmation === "confirmed" ? undefined : styles.hint}>
                          {CONFIRMATION_LABELS[invoice.confirmation] ?? invoice.confirmation}
                          {invoice.source === "download" && " · baixada da Sefaz"}
                        </small>
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
