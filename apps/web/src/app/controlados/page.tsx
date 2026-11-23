import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { dateTimeText } from "../vendas/labels";

export const metadata: Metadata = { title: "Controlados · FarmaERP" };

interface DispensingRow {
  id: string;
  sale_id: string;
  sale_code: string;
  sold_at: string;
  branch_name: string;
  product_code: number;
  product_name: string;
  controlled_class: string;
  batch_number: string | null;
  quantity: string;
  status: "complete" | "pending";
  pending_reason: string | null;
  prescription_type: string | null;
  prescription_number: string | null;
  prescription_date: string | null;
  prescriber: string | null;
  buyer_name: string | null;
  buyer_document_masked: string | null;
  pharmacist_name: string;
}

const TYPE_LABELS: Record<string, string> = {
  notification_a: "Notificação A (amarela)",
  notification_b: "Notificação B (azul)",
  notification_b2: "Notificação B2",
  notification_retinoid: "Notificação de retinoide",
  notification_thalidomide: "Notificação de talidomida",
  special_control: "Receita de controle especial",
  antimicrobial: "Receita de antimicrobiano",
};
const STATUS = { todas: "all", pendentes: "pending", completas: "complete" } as const;
type StatusKey = keyof typeof STATUS;
type SearchParams = Promise<{ situacao?: string; de?: string; ate?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const dayText = (value: string) => value.split("-").reverse().join("/");

export default function ControlledPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando controlados...</p>}>
        <ControlledContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ControlledContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/controlados");
  if (!can(user, "controlled.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Controlados</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas de controlados.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const statusKey: StatusKey = params.situacao && params.situacao in STATUS ? (params.situacao as StatusKey) : "todas";
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : "";
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : "";
  const query = new URLSearchParams({ status: STATUS[statusKey], ...(from ? { from } : {}), ...(to ? { to } : {}) });
  const result = await apiFetch<DispensingRow[]>(`/admin/controlled?${query.toString()}`);
  if (!result.ok) redirectIfNeeded(result.error, "/controlados");
  const pending = result.ok ? result.data.filter((row) => row.status === "pending").length : 0;

  return (
    <>
      <AppHeader user={user} />
      <h1>Controlados</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Vendas de controlados feitas nos PDVs, com a receita, o comprador, o lote e o farmacêutico que liberou. As
          pendentes foram liberadas com o estoque negativo e ficam sem os dados do SNGPC até a tela de manutenção (Etapa
          8). O documento do comprador aparece mascarado.
        </p>
        <nav className={styles.inline} aria-label="Situação">
          {(Object.keys(STATUS) as StatusKey[]).map((key) =>
            key === statusKey ? (
              <strong key={key}>{key[0].toUpperCase() + key.slice(1)}</strong>
            ) : (
              <Link key={key} href={`/controlados?situacao=${key}`}>
                {key[0].toUpperCase() + key.slice(1)}
              </Link>
            ),
          )}
        </nav>
        <form action="/controlados" className={styles.inline}>
          <input type="hidden" name="situacao" value={statusKey} />
          <label>
            De
            <input type="date" name="de" defaultValue={from} />
          </label>
          <label>
            Até
            <input type="date" name="ate" defaultValue={to} />
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && pending > 0 && statusKey !== "completas" && (
          <p className={styles.warning}>
            {pending === 1 ? "1 venda pendente" : `${pending} vendas pendentes`} de dados para o SNGPC.
          </p>
        )}
        {result.ok && result.data.length === 0 && <p className={styles.hint}>Nenhuma venda de controlado no período.</p>}
        {result.ok && result.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Venda</th>
                  <th>Produto e lote</th>
                  <th>Receita</th>
                  <th>Comprador</th>
                  <th>Farmacêutico</th>
                  <th>Situação</th>
                </tr>
              </thead>
              <tbody>
                {result.data.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <Link href={`/vendas/${row.sale_id}`}>{row.sale_code}</Link>
                      <small className={styles.hint}>
                        {dateTimeText(row.sold_at)} · {row.branch_name}
                      </small>
                    </td>
                    <td>
                      {row.product_code} · {row.product_name}
                      <small className={styles.hint}>
                        Lista {row.controlled_class} · {Number(row.quantity).toLocaleString("pt-BR")} un ·{" "}
                        {row.batch_number ? `lote ${row.batch_number}` : "sem lote"}
                      </small>
                    </td>
                    <td>
                      {row.prescription_type ? (
                        <>
                          {TYPE_LABELS[row.prescription_type] ?? row.prescription_type}
                          {row.prescription_number && ` nº ${row.prescription_number}`}
                          <small className={styles.hint}>
                            {row.prescription_date && dayText(row.prescription_date)} · {row.prescriber}
                          </small>
                        </>
                      ) : (
                        "—"
                      )}
                    </td>
                    <td>
                      {row.buyer_name ?? "—"}
                      {row.buyer_document_masked && <small className={styles.hint}>{row.buyer_document_masked}</small>}
                    </td>
                    <td>{row.pharmacist_name}</td>
                    <td>
                      {row.status === "pending" ? (
                        <>
                          <span className={styles.warning}>Pendente</span>
                          <small className={styles.hint}>{row.pending_reason}</small>
                        </>
                      ) : (
                        "Completa"
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
