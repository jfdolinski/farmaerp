import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { dayText, KIND, LOSS_REASON, prescriptionText, quantityText, SngpcBatch, SngpcMovement, todayText } from "./format";
import { OpenSngpcForm, PendingBoard } from "./ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "SNGPC · FarmaERP" };

interface BranchRow {
  branch_id: string;
  branch_name: string;
  opened_at: string | null;
  inventory_pending: number;
  pending: number;
  oldest_pending: string | null;
  confirmed: number;
  send_due: number;
}

const TABS = { pendentes: "pending", conferidas: "confirmed", fora: "disregarded" } as const;
type Tab = keyof typeof TABS;
type SearchParams = Promise<{ filial?: string; situacao?: string; aberto?: string; semlote?: string }>;

export default function SngpcPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando o SNGPC...</p>}>
        <SngpcContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SngpcContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/sngpc");
  if (!can(user, "sngpc.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>SNGPC</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para conferir o SNGPC.</p>
        </section>
      </>
    );
  }
  const { filial, situacao, aberto, semlote } = await searchParams;
  const branches = await apiFetch<BranchRow[]>("/admin/sngpc/branches");
  if (!branches.ok) redirectIfNeeded(branches.error, "/sngpc");
  const list = branches.ok ? branches.data : [];
  const branch = list.find((b) => b.branch_id === filial) ?? list[0];
  const tab: Tab = situacao && situacao in TABS ? (situacao as Tab) : "pendentes";
  const today = todayText();

  let rows: SngpcMovement[] = [];
  let rowsError = null;
  const batches: Record<string, SngpcBatch[]> = {};
  if (branch?.opened_at) {
    const result = await apiFetch<SngpcMovement[]>(
      `/admin/sngpc/branches/${branch.branch_id}/movements?status=${TABS[tab]}`,
    );
    if (!result.ok) {
      redirectIfNeeded(result.error, "/sngpc");
      rowsError = result.error;
    } else {
      rows = result.data;
    }
    // Lotes só dos produtos que precisam escolher lote (venda sem receita ou movimentação sem lote).
    if (tab === "pendentes") {
      const needsBatch = (r: SngpcMovement) =>
        (!r.origin_batch && r.kind !== "inventory") || r.dispensing_status === "pending" || r.dispensing_status === "complemented";
      const products = [...new Set(rows.filter(needsBatch).map((r) => r.product_id))];
      await Promise.all(
        products.map(async (productId) => {
          const found = await apiFetch<SngpcBatch[]>(
            `/admin/sngpc/branches/${branch.branch_id}/batches?productId=${productId}`,
          );
          if (found.ok) batches[productId] = found.data;
        }),
      );
    }
  }
  const tabLink = (key: Tab) => `/sngpc?filial=${branch?.branch_id ?? ""}&situacao=${key}`;

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>SNGPC{branch ? ` · ${branch.branch_name}` : ""}</h1>
        <Link href="/controlados">Vendas de controlados</Link>
      </div>
      {!branches.ok && <ErrorNotice error={branches.error} />}
      {list.length > 1 && (
        <section className={styles.card}>
          <h2>Filiais</h2>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Pendentes</th>
                  <th>Mais antiga</th>
                  <th>Conferidas a enviar</th>
                </tr>
              </thead>
              <tbody>
                {list.map((b) => (
                  <tr key={b.branch_id}>
                    <td>
                      <Link href={`/sngpc?filial=${b.branch_id}`}>{b.branch_name}</Link>
                      {!b.opened_at && <small>SNGPC não aberto</small>}
                    </td>
                    <td>{b.pending}</td>
                    <td>{dayText(b.oldest_pending)}</td>
                    <td>{b.confirmed}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
      {branch && !branch.opened_at && (
        <section className={styles.card}>
          <h2>Abrir o SNGPC</h2>
          <OpenSngpcForm branchId={branch.branch_id} />
        </section>
      )}
      {branch?.opened_at && (
        <>
          <section className={styles.card}>
            <h2>Situação</h2>
            {aberto !== undefined && /^\d+$/.test(aberto) && (
              <p className={styles.success}>SNGPC aberto com o inventário inicial de {aberto} lote(s). Confira com a contagem.</p>
            )}
            {semlote !== undefined && /^[1-9]\d*$/.test(semlote) && (
              <p className={styles.warning}>
                {semlote} saldo(s) de controlado sem lote ou negativo ficaram fora do inventário. Acerte o estoque (lote ou
                ajuste) e inclua o lote no inventário.
              </p>
            )}
            <p>
              Aberto em {new Date(branch.opened_at).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })}. {branch.pending} pendente(s)
              {branch.oldest_pending ? `, a mais antiga de ${dayText(branch.oldest_pending)}` : ""}; {branch.confirmed}{" "}
              conferida(s) aguardando o envio.
            </p>
            {branch.inventory_pending > 0 && (
              <p className={styles.warning}>
                Confira primeiro o inventário inicial ({branch.inventory_pending} lote(s)): as outras movimentações dependem dele.
              </p>
            )}
            {branch.oldest_pending && branch.oldest_pending < sevenDaysBefore(today) && (
              <p className={styles.warning}>Há pendências com mais de 7 dias.</p>
            )}
            {branch.send_due > 0 && (
              <p className={styles.warning}>
                {branch.send_due} movimentação(ões) conferida(s) com a data de envio já chegada. O envio à Anvisa chega na
                próxima versão.
              </p>
            )}
            <p className={styles.inline}>
              <Link href={tabLink("pendentes")}>{tab === "pendentes" ? <strong>Pendentes</strong> : "Pendentes"}</Link>
              <Link href={tabLink("conferidas")}>{tab === "conferidas" ? <strong>Conferidas</strong> : "Conferidas"}</Link>
              <Link href={tabLink("fora")}>{tab === "fora" ? <strong>Fora do SNGPC</strong> : "Fora do SNGPC"}</Link>
            </p>
          </section>
          <section className={styles.card}>
            <h2>
              {tab === "pendentes" ? "Pendentes, na ordem do SNGPC" : tab === "conferidas" ? "Conferidas" : "Fora do SNGPC"}
            </h2>
            <ErrorNotice error={rowsError ?? undefined} />
            {rows.length === 0 && !rowsError && tab !== "pendentes" && <p className={styles.hint}>Nenhuma movimentação.</p>}
            {!rowsError && tab === "pendentes" && (
              <PendingBoard branchId={branch.branch_id} rows={rows} batches={batches} today={today} />
            )}
            {rows.length > 0 && tab !== "pendentes" && (
              <div className={styles.tableWrap}>
                <table>
                  <thead>
                    <tr>
                      <th>Data</th>
                      <th>Movimentação</th>
                      <th>Produto</th>
                      <th>Lote e MS</th>
                      <th>Quantidade</th>
                      <th>{tab === "conferidas" ? "Conferência" : "Motivo"}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row) => (
                      <tr key={row.id}>
                        <td>{dayText(row.reported_on)}</td>
                        <td>
                          {KIND[row.kind] ?? row.kind}
                          {row.counterpart && <small>{row.counterpart}</small>}
                          {row.loss_reason && <small>{LOSS_REASON[row.loss_reason]}</small>}
                          {row.prescription && <small>{prescriptionText(row.prescription)}</small>}
                        </td>
                        <td>{row.product_name}</td>
                        <td>
                          {row.batch_number ?? "Sem lote"}
                          <small>{row.ms_registration ? `MS ${row.ms_registration}` : ""}</small>
                        </td>
                        <td>{quantityText(row.quantity)}</td>
                        <td>
                          {tab === "conferidas" ? (
                            <>
                              {row.confirmed_by_name}
                              <small>envio em {dayText(row.send_on)}</small>
                            </>
                          ) : (
                            row.status_reason
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
      )}
      {list.length === 0 && branches.ok && (
        <section className={styles.card}>
          <p>Nenhuma filial em que você confere o SNGPC.</p>
        </section>
      )}
    </>
  );
}

/** Sete dias antes de hoje, AAAA-MM-DD. */
function sevenDaysBefore(today: string): string {
  const date = new Date(`${today}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() - 7);
  return date.toISOString().slice(0, 10);
}
