import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { dateTimeText } from "../vendas/labels";
import { AUTH_ALERT_LABELS, AUTH_EVENT_LABELS, AUTH_METHOD_LABELS, AUTH_PURPOSE_LABELS } from "./labels";

export const metadata: Metadata = { title: "Entradas no PDV · FarmaERP" };

interface AuthEventRow {
  id: string;
  occurred_at: string;
  branch_name: string;
  terminal_name: string;
  user_id: string;
  user_code: number;
  user_name: string;
  event: string;
  purpose: string;
  method: string;
  authorized_by_name: string | null;
  alert: string | null;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; marcadas?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

export default function PdvAuthEventsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando as entradas...</p>}>
        <PdvAuthEventsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function PdvAuthEventsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/entradas-pdv");
  if (!can(user, "users.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Entradas no PDV</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as entradas no PDV.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : today();
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : from;
  const branch = typeof params.filial === "string" ? params.filial : "";
  const onlyAlerts = params.marcadas === "1";
  const query = new URLSearchParams({ from, to, alerts: onlyAlerts ? "1" : "0", ...(branch ? { branch } : {}) });
  const [events, branches] = await Promise.all([
    apiFetch<AuthEventRow[]>(`/admin/pdv-auth-events?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!events.ok) redirectIfNeeded(events.error, "/entradas-pdv");
  const rows = events.ok ? events.data : [];
  const marked = rows.filter((row) => row.alert !== null).length;

  return (
    <>
      <AppHeader user={user} />
      <h1>Entradas no PDV</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Cada entrada no caixa, liberação e identificação de vendedor feita nos PDVs, com as falhas, os bloqueios por
          tentativas e as entradas liberadas pelo gerente. Chegam pela sincronização, também as feitas sem internet.
        </p>
        <form action="/entradas-pdv" className={styles.inline}>
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
            <input type="checkbox" name="marcadas" value="1" defaultChecked={onlyAlerts} /> Só as marcadas para conferir
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!events.ok && <ErrorNotice error={events.error} />}
        {events.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma entrada no período.</p>}
        {rows.length > 0 && (
          <>
            <p>
              <strong>{rows.length}</strong> {rows.length === 1 ? "registro" : "registros"}
              {marked > 0 && (
                <span className={styles.warning}> · {marked === 1 ? "1 marcado para conferir" : `${marked} marcados para conferir`}</span>
              )}
              {rows.length === 500 && <span className={styles.hint}> · mostrando os 500 mais recentes; filtre o período</span>}
            </p>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Quando</th>
                    <th>Filial e terminal</th>
                    <th>Pessoa</th>
                    <th>Para</th>
                    <th>Forma</th>
                    <th>Resultado</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id}>
                      <td>{dateTimeText(row.occurred_at)}</td>
                      <td>
                        {row.branch_name}
                        <small className={styles.hint}> · {row.terminal_name}</small>
                      </td>
                      <td>
                        {row.user_name}
                        <small className={styles.hint}>Código {row.user_code}</small>
                      </td>
                      <td>{AUTH_PURPOSE_LABELS[row.purpose] ?? row.purpose}</td>
                      <td>
                        {AUTH_METHOD_LABELS[row.method] ?? row.method}
                        {row.authorized_by_name && <small className={styles.hint}>Liberada por {row.authorized_by_name}</small>}
                      </td>
                      <td>
                        <span className={row.event === "success" ? undefined : styles.warning}>
                          {AUTH_EVENT_LABELS[row.event] ?? row.event}
                        </span>
                        {row.alert && <small className={styles.warning}>{AUTH_ALERT_LABELS[row.alert] ?? row.alert}</small>}
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
