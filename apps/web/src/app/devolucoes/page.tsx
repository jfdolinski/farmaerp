import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { DESTINATION_FILTERS, DESTINATION_LABELS, payoutText, type DestinationFilter } from "./labels";

export const metadata: Metadata = { title: "Devoluções · FarmaERP" };

interface ReturnRow {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  returned_at: string;
  sale_id: string;
  sale_code: string;
  operator_name: string;
  authorized_by_name: string | null;
  customer_name: string | null;
  credit_used: string | null;
  agreement_name: string | null;
  reason: string;
  destination: string;
  total: string;
  paid: boolean;
  item_count: number;
  alert: boolean;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; destino?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

export default function ReturnsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando as devoluções...</p>}>
        <ReturnsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ReturnsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/devolucoes");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Devoluções</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as devoluções.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : today();
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : from;
  const branch = typeof params.filial === "string" ? params.filial : "";
  const filter: DestinationFilter = params.destino && params.destino in DESTINATION_FILTERS ? (params.destino as DestinationFilter) : "todos";
  const query = new URLSearchParams({ from, to, destination: DESTINATION_FILTERS[filter], ...(branch ? { branch } : {}) });
  const [returns, branches] = await Promise.all([
    apiFetch<ReturnRow[]>(`/admin/returns?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!returns.ok) redirectIfNeeded(returns.error, "/devolucoes");
  const rows = returns.ok ? returns.data : [];
  const total = rows.reduce((sum, row) => sum + Number(row.total), 0);
  const waiting = rows.filter((row) => row.destination === "cash" && !row.paid).length;

  return (
    <>
      <AppHeader user={user} />
      <h1>Devoluções</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Devoluções feitas nos caixas, só na loja da compra. O valor vira crédito para nova compra, abatimento na fatura do
          convênio ou dinheiro ao cliente; o dinheiro sai por uma sangria com o documento da devolução.
        </p>
        <form action="/devolucoes" className={styles.inline}>
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
            Destino
            <select name="destino" defaultValue={filter}>
              <option value="todos">Todos</option>
              <option value="credito">Crédito para nova compra</option>
              <option value="convenio">Abatimento no convênio</option>
              <option value="dinheiro">Dinheiro</option>
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {filter === "convenio" && (
          <p className={styles.hint}>
            Abatimentos a fazer na próxima fatura de cada convênio. O faturamento dos convênios chega na Etapa 7.
          </p>
        )}
        {!returns.ok && <ErrorNotice error={returns.error} />}
        {returns.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma devolução no período.</p>}
        {rows.length > 0 && (
          <>
            <p>
              <strong>{rows.length}</strong> {rows.length === 1 ? "devolução" : "devoluções"} · <strong>{brl(total)}</strong>
              {waiting > 0 && (
                <span className={styles.warning}>
                  {" "}
                  · {waiting === 1 ? "1 esperando a sangria" : `${waiting} esperando a sangria`}
                </span>
              )}
            </p>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Devolução</th>
                    <th>Venda</th>
                    <th>Filial e terminal</th>
                    <th>Quem fez</th>
                    <th>Motivo</th>
                    <th>Destino</th>
                    <th>Valor</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id}>
                      <td>
                        <Link href={`/devolucoes/${row.id}`}>{row.code}</Link>
                        <small className={styles.hint}>{dateTimeText(row.returned_at)}</small>
                      </td>
                      <td>
                        <Link href={`/vendas/${row.sale_id}`}>{row.sale_code}</Link>
                      </td>
                      <td>
                        {row.branch_name}
                        <small className={styles.hint}> · {row.terminal_name}</small>
                      </td>
                      <td>
                        {row.operator_name}
                        {row.authorized_by_name && <small className={styles.hint}>Liberada por {row.authorized_by_name}</small>}
                        {row.alert && <small className={styles.warning}>Sem a permissão</small>}
                      </td>
                      <td>{row.reason}</td>
                      <td>
                        {DESTINATION_LABELS[row.destination] ?? row.destination}
                        {row.agreement_name && ` · ${row.agreement_name}`}
                        <small className={row.destination === "cash" && !row.paid ? styles.warning : styles.hint}>
                          {payoutText(row.destination, row.paid, Number(row.total), row.credit_used === null ? null : Number(row.credit_used))}
                        </small>
                        {row.customer_name && <small className={styles.hint}>Cliente: {row.customer_name}</small>}
                      </td>
                      <td>
                        {brl(row.total)}
                        <small className={styles.hint}>{row.item_count === 1 ? "1 item" : `${row.item_count} itens`}</small>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </section>
    </>
  );
}
