import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { NOTE_PAYMENT_LABELS, noteText } from "./labels";

export const metadata: Metadata = { title: "Vendas importadas · FarmaERP" };

interface ImportedSaleRow {
  id: string;
  branch_name: string;
  model: string;
  series: number;
  number: string;
  emitted_at: string;
  customer_id: string | null;
  customer_name: string | null;
  total: string;
  item_count: number;
  payment_methods: string[];
  canceled_at: string | null;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; cliente?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const dayText = (date: Date) => date.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const daysAgo = (days: number) => dayText(new Date(Date.now() - days * 86_400_000));

export default function ImportedSalesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando vendas importadas...</p>}>
        <ImportedSalesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ImportedSalesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/vendas-importadas");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Vendas importadas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const customer = typeof params.cliente === "string" && UUID.test(params.cliente) ? params.cliente : "";
  // Com o cliente escolhido, sem data: todas as dele. Sem cliente, os últimos 30 dias.
  const defaultFrom = customer ? "" : daysAgo(30);
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : defaultFrom;
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : customer ? "" : daysAgo(0);
  const branch = typeof params.filial === "string" && UUID.test(params.filial) ? params.filial : "";
  const query = new URLSearchParams({
    ...(from ? { from } : {}),
    ...(to ? { to } : {}),
    ...(branch ? { branch } : {}),
    ...(customer ? { customer } : {}),
  });
  const [sales, branches] = await Promise.all([
    apiFetch<ImportedSaleRow[]>(`/admin/imported-sales?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!sales.ok) redirectIfNeeded(sales.error, "/vendas-importadas");
  const rows = sales.ok ? sales.data : [];
  const valid = rows.filter((row) => row.canceled_at === null);
  const total = valid.reduce((sum, row) => sum + Number(row.total), 0);

  return (
    <>
      <AppHeader user={user} />
      <h1>Vendas importadas</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Vendas trazidas do sistema anterior pela <Link href="/importacoes">importação de notas</Link>, na data da
          emissão. Elas baixaram o estoque e entram no histórico do cliente; as canceladas na Sefaz aparecem marcadas e
          não somam.
        </p>
        <form action="/vendas-importadas" className={styles.inline}>
          {customer && <input type="hidden" name="cliente" value={customer} />}
          <label>
            De
            <input type="date" name="de" defaultValue={from} />
          </label>
          <label>
            Até
            <input type="date" name="ate" defaultValue={to} />
          </label>
          <label>
            Filial
            <select name="filial" defaultValue={branch}>
              <option value="">Todas</option>
              {(branches.ok ? branches.data : []).map((item) => (
                <option key={item.id} value={item.id}>
                  {item.name}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Filtrar</button>
          {customer && <Link href="/vendas-importadas">Ver de todos os clientes</Link>}
        </form>
        {!sales.ok && <ErrorNotice error={sales.error} />}
        {sales.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma venda importada no período.</p>}
        {rows.length > 0 && (
          <>
            <p>
              <strong>{valid.length.toLocaleString("pt-BR")}</strong> {valid.length === 1 ? "venda" : "vendas"} ·{" "}
              <strong>{brl(total)}</strong>
              {rows.length > valid.length && ` · ${rows.length - valid.length} cancelada(s)`}
            </p>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Nota</th>
                    <th>Emissão</th>
                    <th>Filial</th>
                    <th>Cliente</th>
                    <th>Pagamento</th>
                    <th>Itens</th>
                    <th>Total</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id}>
                      <td>
                        <Link href={`/vendas-importadas/${row.id}`}>{noteText(row.model, row.series, row.number)}</Link>
                        {row.canceled_at && <small className={styles.warning}> Cancelada</small>}
                      </td>
                      <td>{dateTimeText(row.emitted_at)}</td>
                      <td>{row.branch_name}</td>
                      <td>
                        {row.customer_id ? (
                          <Link href={`/clientes/${row.customer_id}`}>{row.customer_name}</Link>
                        ) : (
                          "Não identificado"
                        )}
                      </td>
                      <td>{row.payment_methods.map((method) => NOTE_PAYMENT_LABELS[method] ?? method).join(", ")}</td>
                      <td>{row.item_count}</td>
                      <td>{brl(row.total)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
        {sales.ok && rows.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 vendas mais recentes. Diminua o período para ver todas.</p>
        )}
      </section>
    </>
  );
}
