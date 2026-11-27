import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import {
  dayText,
  KIND,
  LOSS_REASON,
  prescriptionText,
  quantityText,
  SngpcBatch,
  SngpcMovement,
  todayText,
} from "./format";
import { CredentialForm, OpenSngpcForm, PendingBoard, ReopenButton } from "./ui";
import styles from "../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../shell/tabs";

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

const TABS = {
  pendentes: "pending",
  conferidas: "confirmed",
  aceitas: "accepted",
  recusadas: "rejected",
  fora: "disregarded",
  envios: "",
} as const;
const TAB_TITLE: Record<string, string> = {
  pendentes: "Pendentes, na ordem do SNGPC",
  conferidas: "Conferidas, esperando o envio",
  aceitas: "Aceitas pela Anvisa",
  recusadas: "Recusadas pela Anvisa",
  fora: "Fora do SNGPC",
  envios: "Envios à Anvisa",
};
const TAB_LABEL: Record<string, string> = {
  pendentes: "Pendentes",
  conferidas: "Conferidas",
  aceitas: "Aceitas",
  recusadas: "Recusadas",
  fora: "Fora do SNGPC",
  envios: "Envios",
};

interface SendInfo {
  credential_at: string | null;
  rejected: number;
  overdue: number;
  live: boolean;
}

interface SubmissionRow {
  id: string;
  kind: "inventory" | "movements";
  status: "built" | "sent" | "accepted" | "rejected";
  period_start: string;
  period_end: string;
  movement_count: number;
  protocol: string | null;
  sent_at: string | null;
  result_at: string | null;
  reject_reason: string | null;
  attempts: number;
  last_error: string | null;
  created_at: string;
}

const SUBMISSION_STATUS: Record<string, string> = {
  built: "Montada, esperando o envio",
  sent: "Enviada, esperando a Anvisa",
  accepted: "Aceita",
  rejected: "Recusada",
};
const momentText = (value: string | null) =>
  value
    ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" })
    : "";
type Tab = keyof typeof TABS;
type SearchParams = Promise<{
  filial?: string;
  aba?: string | string[];
  situacao?: string;
  aberto?: string;
  semlote?: string;
}>;

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
  const { filial, aba, situacao, aberto, semlote } = await searchParams;
  const branches = await apiFetch<BranchRow[]>("/admin/sngpc/branches");
  if (!branches.ok) redirectIfNeeded(branches.error, "/sngpc");
  const list = branches.ok ? branches.data : [];
  const branch = list.find((b) => b.branch_id === filial) ?? list[0];
  const today = todayText();

  let rows: SngpcMovement[] = [];
  let rowsError = null;
  let sendInfo: SendInfo | null = null;
  let submissions: SubmissionRow[] = [];
  const batches: Record<string, SngpcBatch[]> = {};
  if (branch?.opened_at) {
    const info = await apiFetch<SendInfo>(`/admin/sngpc/branches/${branch.branch_id}/send-info`);
    if (info.ok) sendInfo = info.data;
  }
  const late = Boolean(branch?.oldest_pending && branch.oldest_pending < sevenDaysBefore(today));
  const tabs: TabItem[] = [
    {
      id: "situacao",
      label: "Situação",
      attention: Boolean(sendInfo && (!sendInfo.credential_at || sendInfo.overdue > 0)),
    },
    ...(Object.keys(TABS) as Tab[]).map((key) => ({
      id: key,
      label: TAB_LABEL[key],
      count:
        key === "pendentes"
          ? branch?.pending
          : key === "conferidas"
            ? branch?.confirmed
            : key === "recusadas"
              ? sendInfo?.rejected
              : undefined,
      attention:
        key === "pendentes"
          ? Boolean(branch && (branch.inventory_pending > 0 || late))
          : key === "recusadas" && (sendInfo?.rejected ?? 0) > 0,
    })),
  ];
  // "situacao" era o parâmetro das abas antes do componente de abas; continua valendo para endereços antigos.
  const tab = activeTab(tabs, aba ?? situacao);
  if (branch?.opened_at && tab !== "situacao") {
    if (tab === "envios") {
      const result = await apiFetch<SubmissionRow[]>(`/admin/sngpc/branches/${branch.branch_id}/submissions`);
      if (!result.ok) {
        redirectIfNeeded(result.error, "/sngpc");
        rowsError = result.error;
      } else {
        submissions = result.data;
      }
    } else {
      const result = await apiFetch<SngpcMovement[]>(
        `/admin/sngpc/branches/${branch.branch_id}/movements?status=${TABS[tab as Tab]}`,
      );
      if (!result.ok) {
        redirectIfNeeded(result.error, "/sngpc");
        rowsError = result.error;
      } else {
        rows = result.data;
      }
    }
    // Lotes só dos produtos que precisam escolher lote (venda sem receita ou movimentação sem lote).
    if (tab === "pendentes") {
      const needsBatch = (r: SngpcMovement) =>
        (!r.origin_batch && r.kind !== "inventory") ||
        r.dispensing_status === "pending" ||
        r.dispensing_status === "complemented";
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
  const branchTable = list.length > 1 && (
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
  );

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>SNGPC{branch ? ` · ${branch.branch_name}` : ""}</h1>
        <Link href="/controlados">Vendas de controlados</Link>
      </div>
      {!branches.ok && <ErrorNotice error={branches.error} />}
      {!branch?.opened_at && branchTable}
      {branch && !branch.opened_at && (
        <section className={styles.card}>
          <h2>Abrir o SNGPC</h2>
          <OpenSngpcForm branchId={branch.branch_id} />
        </section>
      )}
      {branch?.opened_at && (
        <Tabs base="/sngpc" items={tabs} active={tab} keep={{ filial: branch.branch_id }}>
          {tab === "situacao" && (
            <>
              {branchTable}
              <section className={styles.card}>
                <h2>Situação</h2>
                {aberto !== undefined && /^\d+$/.test(aberto) && (
                  <p className={styles.success}>
                    SNGPC aberto com o inventário inicial de {aberto} lote(s). Confira com a contagem.
                  </p>
                )}
                {semlote !== undefined && /^[1-9]\d*$/.test(semlote) && (
                  <p className={styles.warning}>
                    {semlote} saldo(s) de controlado sem lote ou negativo ficaram fora do inventário. Acerte o estoque
                    (lote ou ajuste) e inclua o lote no inventário.
                  </p>
                )}
                <p>
                  Aberto em {new Date(branch.opened_at).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })}.{" "}
                  {branch.pending} pendente(s)
                  {branch.oldest_pending ? `, a mais antiga de ${dayText(branch.oldest_pending)}` : ""};{" "}
                  {branch.confirmed} conferida(s) aguardando o envio.
                </p>
                {branch.inventory_pending > 0 && (
                  <p className={styles.warning}>
                    Confira primeiro o inventário inicial ({branch.inventory_pending} lote(s)): as outras movimentações
                    dependem dele.
                  </p>
                )}
                {branch.oldest_pending && branch.oldest_pending < sevenDaysBefore(today) && (
                  <p className={styles.warning}>Há pendências com mais de 7 dias.</p>
                )}
                {sendInfo && !sendInfo.credential_at && (
                  <p className={styles.warning}>Sem a credencial do SNGPC da filial, nada é enviado à Anvisa.</p>
                )}
                {sendInfo && !sendInfo.live && (
                  <p className={styles.warning}>
                    O envio real à Anvisa ainda está desligado: as remessas ficam montadas e saem quando ele for ligado.
                  </p>
                )}
                {sendInfo && sendInfo.overdue > 0 && (
                  <p className={styles.warning}>
                    {sendInfo.overdue} movimentação(ões) com a data de envio passada e ainda não aceita(s).
                  </p>
                )}
                {sendInfo && sendInfo.rejected > 0 && (
                  <p className={styles.warning}>
                    {sendInfo.rejected} movimentação(ões) recusada(s) pela Anvisa: reabra, corrija e confira de novo.
                    Elas seguram as seguintes do mesmo produto.
                  </p>
                )}
                {sendInfo?.credential_at && (
                  <p className={styles.hint}>
                    Credencial do SNGPC cadastrada em{" "}
                    {new Date(sendInfo.credential_at).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })}.
                  </p>
                )}
                {sendInfo && <CredentialForm branchId={branch.branch_id} registeredAt={sendInfo.credential_at} />}
              </section>
            </>
          )}
          {tab !== "situacao" && (
            <section className={styles.card}>
              <h2>{TAB_TITLE[tab]}</h2>
              <ErrorNotice error={rowsError ?? undefined} />
              {rows.length === 0 && !rowsError && tab !== "pendentes" && tab !== "envios" && (
                <p className={styles.hint}>Nenhuma movimentação.</p>
              )}
              {tab === "envios" && !rowsError && submissions.length === 0 && (
                <p className={styles.hint}>Nenhuma remessa ainda.</p>
              )}
              {tab === "envios" && submissions.length > 0 && (
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Remessa</th>
                        <th>Situação</th>
                        <th>Protocolo</th>
                        <th />
                      </tr>
                    </thead>
                    <tbody>
                      {submissions.map((s) => (
                        <tr key={s.id}>
                          <td>
                            {s.kind === "inventory" ? "Inventário inicial" : "Movimentações"}
                            <small>
                              {dayText(s.period_start)} a {dayText(s.period_end)} · {s.movement_count} movimentação(ões)
                            </small>
                          </td>
                          <td>
                            {SUBMISSION_STATUS[s.status]}
                            {s.sent_at && <small>Enviada em {momentText(s.sent_at)}</small>}
                            {s.result_at && <small>Resposta em {momentText(s.result_at)}</small>}
                            {s.reject_reason && <small className={styles.warning}>{s.reject_reason}</small>}
                            {s.last_error && <small className={styles.warning}>Última tentativa: {s.last_error}</small>}
                          </td>
                          <td>{s.protocol ?? "-"}</td>
                          <td>
                            {s.status !== "built" && <a href={`/sngpc/remessas/${s.id}/xml`}>Baixar o arquivo</a>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
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
                        <th>{tab === "conferidas" || tab === "aceitas" ? "Conferência" : "Motivo"}</th>
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
                            {tab === "conferidas" || tab === "aceitas" ? (
                              <>
                                {row.confirmed_by_name}
                                <small>envio em {dayText(row.send_on)}</small>
                              </>
                            ) : (
                              <>
                                {row.status_reason}
                                {tab === "recusadas" && <ReopenButton movementId={row.id} />}
                              </>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          )}
        </Tabs>
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
