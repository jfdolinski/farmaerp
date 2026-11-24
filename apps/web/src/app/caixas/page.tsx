import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { differenceText } from "./labels";

export const metadata: Metadata = { title: "Caixas · FarmaERP" };

interface SessionRow {
  id: string;
  branch_name: string;
  terminal_name: string;
  opened_by_name: string;
  opened_at: string;
  closed_by_name: string | null;
  closed_at: string | null;
  status: "open" | "closed";
  opening_float: string;
  sale_count: number;
  sales_total: string;
  withdrawals: string;
  supplies: string;
  counted_total: string | null;
  difference_total: string | null;
  alert_count: number;
}

const STATUS = { todos: "all", abertos: "open", fechados: "closed" } as const;
type StatusKey = keyof typeof STATUS;
type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; situacao?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

export default function CashSessionsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando os caixas...</p>}>
        <CashSessionsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function CashSessionsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/caixas");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Caixas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os caixas.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : today();
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : from;
  const branch = typeof params.filial === "string" ? params.filial : "";
  const statusKey: StatusKey = params.situacao && params.situacao in STATUS ? (params.situacao as StatusKey) : "todos";
  const query = new URLSearchParams({ from, to, status: STATUS[statusKey], ...(branch ? { branch } : {}) });
  const [sessions, branches] = await Promise.all([
    apiFetch<SessionRow[]>(`/admin/cash-sessions?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!sessions.ok) redirectIfNeeded(sessions.error, "/caixas");
  const rows = sessions.ok ? sessions.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Caixas</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Turnos de caixa pela hora da abertura, com as sangrias, os suprimentos e a conferência do fechamento. O
          operador fecha sem ver o esperado; a diferença aparece só aqui.
        </p>
        <form action="/caixas" className={styles.inline}>
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
            <select name="situacao" defaultValue={statusKey}>
              <option value="todos">Todos</option>
              <option value="abertos">Abertos</option>
              <option value="fechados">Fechados</option>
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!sessions.ok && <ErrorNotice error={sessions.error} />}
        {sessions.ok && rows.length === 0 && <p className={styles.hint}>Nenhum turno no período.</p>}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Abertura</th>
                  <th>Filial e terminal</th>
                  <th>Operador</th>
                  <th>Vendas</th>
                  <th>Sangrias</th>
                  <th>Suprimentos</th>
                  <th>Fechamento</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <Link href={`/caixas/${row.id}`}>{dateTimeText(row.opened_at)}</Link>
                      <small className={styles.hint}>Fundo de troco {brl(row.opening_float)}</small>
                    </td>
                    <td>
                      {row.branch_name}
                      <small className={styles.hint}> · {row.terminal_name}</small>
                    </td>
                    <td>{row.opened_by_name}</td>
                    <td>
                      {brl(row.sales_total)}
                      <small className={styles.hint}>
                        {row.sale_count === 1 ? "1 venda" : `${row.sale_count.toLocaleString("pt-BR")} vendas`}
                      </small>
                    </td>
                    <td>{Number(row.withdrawals) > 0 ? brl(row.withdrawals) : "—"}</td>
                    <td>{Number(row.supplies) > 0 ? brl(row.supplies) : "—"}</td>
                    <td>
                      {row.status === "open" ? (
                        "Aberto"
                      ) : (
                        <>
                          {dateTimeText(row.closed_at!)}
                          <small className={Number(row.difference_total) === 0 ? styles.hint : styles.warning}>
                            {differenceText(row.difference_total)}
                          </small>
                        </>
                      )}
                      {row.alert_count > 0 && (
                        <small className={styles.warning}>
                          {row.alert_count === 1 ? "1 alerta" : `${row.alert_count} alertas`}
                        </small>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {sessions.ok && sessions.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra os 500 turnos mais recentes do período. Diminua o período para ver todos.</p>
        )}
      </section>
    </>
  );
}
