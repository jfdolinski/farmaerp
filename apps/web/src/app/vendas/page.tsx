import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText, FISCAL_LABELS, PAYMENT_LABELS } from "./labels";

export const metadata: Metadata = { title: "Vendas · FarmaERP" };

interface SaleRow {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  sold_at: string;
  operator_name: string;
  customer_name: string | null;
  total: string;
  item_count: number;
  payment_methods: string[];
  fiscal_status: string;
  alert_count: number;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; alertas?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

export default function SalesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando vendas...</p>}>
        <SalesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SalesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/vendas");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Vendas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : today();
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : from;
  const branch = typeof params.filial === "string" ? params.filial : "";
  const onlyAlerts = params.alertas === "1";
  const query = new URLSearchParams({ from, to, ...(branch ? { branch } : {}) });
  const [sales, branches] = await Promise.all([
    apiFetch<SaleRow[]>(`/admin/sales?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!sales.ok) redirectIfNeeded(sales.error, "/vendas");
  const rows = sales.ok ? sales.data.filter((row) => !onlyAlerts || row.alert_count > 0) : [];
  const total = rows.reduce((sum, row) => sum + Number(row.total), 0);

  return (
    <>
      <AppHeader user={user} />
      <h1>Vendas</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Vendas que chegaram dos PDVs, pela hora em que aconteceram na loja. A nota fiscal fica pendente até a emissão
          pelo PDV. Os alertas mostram o que a central achou ao receber: a venda vale, mas merece uma olhada.
        </p>
        <form action="/vendas" className={styles.inline}>
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
            <input type="checkbox" name="alertas" value="1" defaultChecked={onlyAlerts} />
            Só com alerta
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!sales.ok && <ErrorNotice error={sales.error} />}
        {sales.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma venda no período.</p>}
        {rows.length > 0 && (
          <>
            <p>
              <strong>{rows.length.toLocaleString("pt-BR")}</strong> {rows.length === 1 ? "venda" : "vendas"} ·{" "}
              <strong>{brl(total)}</strong>
            </p>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Venda</th>
                    <th>Quando</th>
                    <th>Filial e terminal</th>
                    <th>Operador</th>
                    <th>Cliente</th>
                    <th>Pagamento</th>
                    <th>Total</th>
                    <th>Situação</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id}>
                      <td>
                        <Link href={`/vendas/${row.id}`}>{row.code}</Link>
                      </td>
                      <td>{dateTimeText(row.sold_at)}</td>
                      <td>
                        {row.branch_name}
                        <small className={styles.hint}> · {row.terminal_name}</small>
                      </td>
                      <td>{row.operator_name}</td>
                      <td>{row.customer_name ?? "Não identificado"}</td>
                      <td>{row.payment_methods.map((method) => PAYMENT_LABELS[method] ?? method).join(", ")}</td>
                      <td>{brl(row.total)}</td>
                      <td>
                        <small>{FISCAL_LABELS[row.fiscal_status] ?? row.fiscal_status}</small>
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
          </>
        )}
        {sales.ok && sales.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 vendas mais recentes do período. Diminua o período para ver todas.</p>
        )}
      </section>
    </>
  );
}
