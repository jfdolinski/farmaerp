import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { dateText, moneyText, STATUS_LABELS } from "./format";
import { UploadForm } from "./ui";

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
}

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
  const status = situacao === "review" || situacao === "not_postable" || situacao === "posted" ? situacao : "";
  const invoices = await apiFetch<InvoiceListRow[]>(`/admin/purchase-invoices?status=${status}`);
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
      <section className={styles.card}>
        <form action="/notas" className={styles.inline}>
          <label>
            Situação
            <select name="situacao" defaultValue={status}>
              <option value="">Todas</option>
              <option value="review">Em conferência</option>
              <option value="posted">Lançada no estoque</option>
              <option value="not_postable">Não vai para o estoque</option>
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
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className={styles.hint}>
          Nesta etapa a nota é só conferida: o lançamento no estoque chega no próximo passo.
        </p>
      </section>
    </>
  );
}
