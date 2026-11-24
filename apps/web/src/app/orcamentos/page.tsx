import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { QUOTE_FILTERS, QUOTE_STATUS_LABELS, type QuoteFilter } from "./labels";

export const metadata: Metadata = { title: "Orçamentos · FarmaERP" };

interface QuoteRow {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  seller_name: string;
  customer_name: string | null;
  card_number: number | null;
  status: string;
  quoted_at: string;
  expires_at: string;
  total: string;
  item_count: number;
  sale_id: string | null;
  sale_code: string | null;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; situacao?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

export default function QuotesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando os orçamentos...</p>}>
        <QuotesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function QuotesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/orcamentos");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Orçamentos</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os orçamentos.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : today();
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : from;
  const branch = typeof params.filial === "string" ? params.filial : "";
  const filter: QuoteFilter = params.situacao && params.situacao in QUOTE_FILTERS ? (params.situacao as QuoteFilter) : "todos";
  const query = new URLSearchParams({ from, to, status: QUOTE_FILTERS[filter], ...(branch ? { branch } : {}) });
  const [quotes, branches] = await Promise.all([
    apiFetch<QuoteRow[]>(`/admin/quotes?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!quotes.ok) redirectIfNeeded(quotes.error, "/orcamentos");
  const rows = quotes.ok ? quotes.data : [];
  // Conversão: só faz sentido olhando todos os orçamentos do período.
  const converted = rows.filter((row) => row.status === "converted").length;
  const finished = rows.filter((row) => row.status !== "open").length;

  return (
    <>
      <AppHeader user={user} />
      <h1>Orçamentos</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Orçamentos feitos nos terminais de orçamento, pela hora em que foram feitos. A plaquinha fica com um orçamento
          aberto por loja: usada de novo, o anterior fica substituído. O aberto que passa da validade fica vencido.
        </p>
        <form action="/orcamentos" className={styles.inline}>
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
          <label>
            Situação
            <select name="situacao" defaultValue={filter}>
              <option value="todos">Todas</option>
              <option value="abertos">Abertos</option>
              <option value="convertidos">Viraram venda</option>
              <option value="substituidos">Substituídos</option>
              <option value="vencidos">Vencidos</option>
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!quotes.ok && <ErrorNotice error={quotes.error} />}
        {quotes.ok && rows.length === 0 && <p className={styles.hint}>Nenhum orçamento no período.</p>}
        {filter === "todos" && finished > 0 && (
          <p>
            Conversão: <strong>{Math.round((converted / finished) * 100)}%</strong> dos orçamentos encerrados viraram venda (
            {converted} de {finished}).
          </p>
        )}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Orçamento</th>
                  <th>Quando</th>
                  <th>Filial e terminal</th>
                  <th>Vendedor</th>
                  <th>Cliente</th>
                  <th>Total</th>
                  <th>Situação</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <Link href={`/orcamentos/${row.id}`}>{row.code}</Link>
                      {row.card_number !== null && <small className={styles.hint}>Plaquinha {row.card_number}</small>}
                    </td>
                    <td>
                      {dateTimeText(row.quoted_at)}
                      <small className={styles.hint}>Vale até {dateTimeText(row.expires_at)}</small>
                    </td>
                    <td>
                      {row.branch_name}
                      <small className={styles.hint}> · {row.terminal_name}</small>
                    </td>
                    <td>{row.seller_name}</td>
                    <td>{row.customer_name ?? "Não identificado"}</td>
                    <td>
                      {brl(row.total)}
                      <small className={styles.hint}>{row.item_count === 1 ? "1 item" : `${row.item_count} itens`}</small>
                    </td>
                    <td>
                      {QUOTE_STATUS_LABELS[row.status] ?? row.status}
                      {row.sale_id && (
                        <small className={styles.hint}>
                          <Link href={`/vendas/${row.sale_id}`}>Venda {row.sale_code}</Link>
                        </small>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {quotes.ok && quotes.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra os 500 orçamentos mais recentes do período. Diminua o período para ver todos.</p>
        )}
      </section>
    </>
  );
}
