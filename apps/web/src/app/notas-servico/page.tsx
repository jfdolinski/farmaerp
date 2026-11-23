import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import {
  competenceText,
  currentMonth,
  documentText,
  ISS_WITHHOLDING_LABELS,
  moneyText,
  SERVICE_STATUS_LABELS,
} from "./format";

export const metadata: Metadata = { title: "Notas de serviço · FarmaERP" };

interface ServiceInvoiceRow {
  id: string;
  branch_name: string;
  number: string;
  issued_at: string;
  competence: string;
  provider_document: string | null;
  provider_name: string;
  description: string;
  service_value: string;
  iss_value: string;
  iss_withholding: number | null;
  total_withheld: string;
  net_value: string;
  status: string;
}

type SearchParams = Promise<{ de?: string; ate?: string; situacao?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

export default function ServiceInvoicesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando notas de serviço...</p>}>
        <ServiceInvoicesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ServiceInvoicesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/notas-servico");
  if (!can(user, "purchases.view") && !can(user, "purchases.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Notas de serviço</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as notas de serviço.</p>
        </section>
      </>
    );
  }

  const params = await searchParams;
  const month = currentMonth();
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : month.from;
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : month.to;
  const status = ["active", "cancelled", "replaced"].includes(params.situacao ?? "") ? (params.situacao as string) : "";
  const query = new URLSearchParams({ from, to, ...(status ? { status } : {}) });
  const result = await apiFetch<ServiceInvoiceRow[]>(`/admin/service-invoices?${query.toString()}`);
  if (!result.ok) redirectIfNeeded(result.error, "/notas-servico");
  const rows = result.ok ? result.data : [];
  const valid = rows.filter((row) => row.status === "active");
  const sum = (field: "service_value" | "total_withheld" | "net_value") =>
    valid.reduce((total, row) => total + Number(row[field]), 0);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Notas de serviço</h1>
        <Link href="/notas">Notas de compra</Link>
      </div>
      <section className={styles.card}>
        <p className={styles.hint}>
          Notas de serviço em que a filial é a tomadora, baixadas do Ambiente Nacional da NFS-e pelo download automático
          ligado em Fiscal. Elas não mexem no estoque: ficam registradas para o contas a pagar e para o contador.
        </p>
        <form action="/notas-servico" className={styles.inline}>
          <label>
            Competência de
            <input type="date" name="de" defaultValue={from} />
          </label>
          <label>
            até
            <input type="date" name="ate" defaultValue={to} />
          </label>
          <label>
            Situação
            <select name="situacao" defaultValue={status}>
              <option value="">Todas</option>
              <option value="active">Válida</option>
              <option value="cancelled">Cancelada pelo prestador</option>
              <option value="replaced">Substituída</option>
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma nota de serviço neste período.</p>}
        {rows.length > 0 && (
          <>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Nota</th>
                    <th>Prestador</th>
                    <th>Filial</th>
                    <th>Competência</th>
                    <th>Serviço</th>
                    <th>Valor líquido</th>
                    <th>Situação</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id}>
                      <td>
                        <Link href={`/notas-servico/${row.id}`}>{row.number}</Link>
                      </td>
                      <td>
                        {row.provider_name}
                        <small className={styles.hint}> {documentText(row.provider_document)}</small>
                      </td>
                      <td>{row.branch_name}</td>
                      <td>{competenceText(row.competence)}</td>
                      <td>
                        {moneyText(row.service_value)}
                        {row.iss_withholding !== null && (
                          <small className={styles.hint}> {ISS_WITHHOLDING_LABELS[row.iss_withholding]}</small>
                        )}
                      </td>
                      <td>{moneyText(row.net_value)}</td>
                      <td>
                        <span className={row.status === "active" ? undefined : styles.warning}>
                          {SERVICE_STATUS_LABELS[row.status] ?? row.status}
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p>
              Notas válidas no período: {valid.length.toLocaleString("pt-BR")} · Serviços {moneyText(sum("service_value"))}{" "}
              · Retenções {moneyText(sum("total_withheld"))} · Líquido {moneyText(sum("net_value"))}
            </p>
            {rows.length >= 200 && (
              <p className={styles.warning}>A lista mostra as 200 notas mais recentes. Diminua o período para ver todas.</p>
            )}
          </>
        )}
      </section>
    </>
  );
}
