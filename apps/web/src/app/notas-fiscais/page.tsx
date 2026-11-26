import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { CancelForm, DismissButton, DocumentActions } from "./ui";

export const metadata: Metadata = { title: "Notas fiscais · FarmaERP" };

interface FiscalRow {
  id: string;
  sale_id: string;
  sale_code: string;
  branch_name: string;
  terminal_name: string;
  series: number;
  number: string;
  access_key: string;
  environment: number;
  emission_type: number;
  status: string;
  status_code: string | null;
  reason: string | null;
  emitted_at: string;
  authorized_at: string | null;
  total: string;
  resend_attempted_at: string | null;
  resend_status: string | null;
  resend_message: string | null;
  alert: boolean;
  cancel_note: string | null;
  cancelable_until: string | null;
}

const STATUS_LABELS: Record<string, string> = {
  authorized: "Autorizada",
  contingency: "Em contingência",
  pending: "Pendente",
  rejected: "Rejeitada",
  canceled: "Cancelada",
};

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; situacao?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const dayText = (date: Date) => date.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const daysAgo = (days: number) => dayText(new Date(Date.now() - days * 86_400_000));

export default function FiscalDocumentsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando notas fiscais...</p>}>
        <FiscalContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

function Row({ row, canCancel, canResend }: { row: FiscalRow; canCancel: boolean; canResend: boolean }) {
  return (
    <tr>
      <td>
        NFC-e {row.series}/{row.number}
        {row.environment === 2 && <small className={styles.hint}> · homologação</small>}
        <br />
        <small className={styles.hint}>{row.access_key}</small>
      </td>
      <td>
        {row.status === "canceled" ? row.sale_code : <Link href={`/vendas/${row.sale_id}`}>{row.sale_code}</Link>}
        <br />
        <small className={styles.hint}>
          {row.branch_name} · {row.terminal_name}
        </small>
      </td>
      <td>{dateTimeText(row.emitted_at)}</td>
      <td>
        {STATUS_LABELS[row.status] ?? row.status}
        {row.emission_type === 9 && row.status !== "authorized" && <small className={styles.hint}> (emitida sem internet)</small>}
        {row.status_code && row.status !== "authorized" && (
          <small className={styles.hint}>
            <br />
            {row.status_code} {row.reason}
          </small>
        )}
        {row.resend_status && (
          <small className={row.resend_status === "refused" ? styles.warning : styles.hint}>
            <br />
            Reenvio pela central: {row.resend_status === "authorized" ? "autorizada" : row.resend_status === "refused" ? "recusada" : "sem Sefaz"}
            {row.resend_message && ` · ${row.resend_message}`}
          </small>
        )}
        {row.cancel_note && (
          <small className={styles.warning}>
            <br />
            {row.cancel_note}
          </small>
        )}
      </td>
      <td>{brl(row.total)}</td>
      <td>
        <details>
          <summary>Ações</summary>
          <div className={styles.stack}>
            <DocumentActions id={row.id} canResend={canResend && ["pending", "contingency", "rejected"].includes(row.status)} />
            {canCancel && row.status === "authorized" && row.cancelable_until && <CancelForm id={row.id} until={row.cancelable_until} />}
            <p>
              <a href={`/notas-fiscais/${row.id}/xml`}>Baixar o XML</a>
              {row.status === "canceled" && (
                <>
                  {" "}
                  · <a href={`/notas-fiscais/${row.id}/xml?kind=cancel`}>XML do cancelamento</a>
                </>
              )}
            </p>
            {row.alert && <DismissButton id={row.id} />}
          </div>
        </details>
      </td>
    </tr>
  );
}

function Table({ rows, canCancel, canResend }: { rows: FiscalRow[]; canCancel: boolean; canResend: boolean }) {
  return (
    <div className={styles.tableWrap}>
      <table>
        <thead>
          <tr>
            <th>Nota</th>
            <th>Venda</th>
            <th>Emissão</th>
            <th>Situação</th>
            <th>Total</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <Row key={row.id} row={row} canCancel={canCancel} canResend={canResend} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

async function FiscalContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/notas-fiscais");
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Notas fiscais</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : daysAgo(7);
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : daysAgo(0);
  const branch = typeof params.filial === "string" && UUID.test(params.filial) ? params.filial : "";
  const status = typeof params.situacao === "string" && params.situacao in STATUS_LABELS ? params.situacao : "";
  const query = new URLSearchParams({ from, to, ...(branch ? { branch } : {}), ...(status ? { status } : {}) });
  const [documents, alerts, branches] = await Promise.all([
    apiFetch<FiscalRow[]>(`/admin/fiscal-documents?${query.toString()}`),
    apiFetch<FiscalRow[]>("/admin/fiscal-documents?alerts=1"),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!documents.ok) redirectIfNeeded(documents.error, "/notas-fiscais");
  const canCancel = can(user, "fiscal.cancel");
  const canResend = can(user, "fiscal.void");

  return (
    <>
      <AppHeader user={user} />
      <h1>Notas fiscais</h1>
      <p className={styles.hint}>
        NFC-e emitidas nos caixas. A central consulta a Sefaz e, de hora em hora, reenvia até 30 notas que ficaram paradas
        (em contingência ou pendentes) há mais da metade do prazo; a recusada vira aviso. O cancelamento vale até 30
        minutos depois da autorização e desfaz a venda junto.{" "}
        {canResend && <Link href="/notas-fiscais/inutilizacao">Inutilizar numeração</Link>}
      </p>

      {alerts.ok && alerts.data.length > 0 && (
        <section className={styles.card}>
          <h2>Avisos</h2>
          <p className={styles.hint}>
            Notas que a central não conseguiu resolver sozinha. Confira o motivo, corrija (por exemplo, o cadastro do produto
            ou o certificado) e reenvie; ou marque como visto.
          </p>
          <Table rows={alerts.data} canCancel={canCancel} canResend={canResend} />
        </section>
      )}

      <section className={styles.card}>
        <form action="/notas-fiscais" className={styles.inline}>
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
            <select name="situacao" defaultValue={status}>
              <option value="">Todas</option>
              {Object.entries(STATUS_LABELS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!documents.ok && <ErrorNotice error={documents.error} />}
        {documents.ok && documents.data.length === 0 && <p className={styles.hint}>Nenhuma nota no período.</p>}
        {documents.ok && documents.data.length > 0 && <Table rows={documents.data} canCancel={canCancel} canResend={canResend} />}
        {documents.ok && documents.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 notas mais recentes. Diminua o período para ver todas.</p>
        )}
      </section>
    </>
  );
}
