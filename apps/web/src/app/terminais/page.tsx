import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import {
  AddTerminal,
  ApproveForm,
  AutoRefresh,
  ReasonAction,
  UnblockButton,
} from "./ui";
import styles from "./page.module.css";

export const metadata: Metadata = { title: "Terminais · FarmaERP" };

interface TerminalSeries {
  terminal_id: string;
  model: "55" | "65";
  series: number;
}

interface MonitorRow {
  id: string;
  number: number | null;
  branch_name: string;
  name: string | null;
  profile: string | null;
  status: "pending" | "active" | "blocked" | "revoked";
  platform: string | null;
  device_name: string | null;
  key_storage: string | null;
  app_version: string | null;
  last_seen_at: string | null;
  connectivity: "online" | "offline";
  last_sync_at: string | null;
  outbox_pending: number | null;
  initial_load_at: string | null;
  last_pull_at: string | null;
  last_push_at: string | null;
  pending_changes: number | null;
  open_conflicts: number;
}

const STATUS_LABELS = {
  pending: "Aguardando aprovação",
  active: "Ativo",
  blocked: "Bloqueado",
  revoked: "Revogado",
};
const PROFILE_LABELS: Record<string, string> = {
  quote: "Orçamento",
  cashier: "Caixa",
  self_service: "Autoatendimento",
};
// A central conta até 10.001 mudanças à espera, para não pesar a tela.
const LAG_LIMIT = 10000;

function lagText(count: number | null): string {
  if (count === null) return "—";
  if (count > LAG_LIMIT) return "mais de 10.000";
  return count.toLocaleString("pt-BR");
}

/** Situação da sincronização do terminal, em linhas curtas. */
function SyncSummary({ terminal }: { terminal: MonitorRow }) {
  if (terminal.status !== "active" && !terminal.initial_load_at) return <>—</>;
  return (
    <>
      {terminal.initial_load_at ? (
        <small>Carga inicial: {formatDate(terminal.initial_load_at)}</small>
      ) : (
        <small className={styles.warning}>Carga inicial ainda não concluída</small>
      )}
      <small>Desceu: {formatDate(terminal.last_pull_at)}</small>
      <small>Subiu: {formatDate(terminal.last_push_at)}</small>
      <small>
        A enviar: {terminal.outbox_pending ?? "—"} · A receber: {lagText(terminal.pending_changes)}
      </small>
      {terminal.open_conflicts > 0 && (
        <small>
          <Link href="/sincronizacao" className={styles.warning}>
            {terminal.open_conflicts === 1 ? "1 conflito aberto" : `${terminal.open_conflicts} conflitos abertos`}
          </Link>
        </small>
      )}
    </>
  );
}

function formatDate(value: string | null): string {
  return value
    ? new Date(value).toLocaleString("pt-BR", {
        timeZone: "America/Sao_Paulo",
        dateStyle: "short",
        timeStyle: "short",
      })
    : "Nunca";
}

export default function TerminalsPage() {
  return (
    <main className={styles.page}>
      <AutoRefresh />
      <Suspense fallback={<p className={styles.hint}>Carregando terminais...</p>}>
        <TerminalsContent />
      </Suspense>
    </main>
  );
}

async function TerminalsContent() {
  const user = await requireUser("/terminais");
  const canView = can(user, "terminals.view");
  const canRequest = can(user, "terminals.request");
  const series = await apiFetch<TerminalSeries[]>("/admin/fiscal/series");
  const seriesOf = (id: string) =>
    (series.ok ? series.data : [])
      .filter((item) => item.terminal_id === id)
      .map((item) => `${item.model === "65" ? "NFC-e" : "NF-e"} série ${item.series}`)
      .join(" · ");
  const canApprove = can(user, "terminals.approve");
  const canBlock = can(user, "terminals.block");
  const canRevoke = can(user, "terminals.revoke");
  const [terminals, branches] = await Promise.all([
    apiFetch<MonitorRow[]>("/admin/terminals"),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);

  if (!terminals.ok) redirectIfNeeded(terminals.error, "/terminais");

  return (
    <>
      <AppHeader user={user} />
      <h1>Terminais</h1>

      {canRequest && <AddTerminal branches={branches.ok ? branches.data : []} />}

      {!canView && !canRequest && (
        <section className={styles.card}>
          <p>Você não tem permissão para ver os terminais.</p>
        </section>
      )}
      {canView && <section className={styles.card}>
        <h2>Situação dos terminais</h2>
        {!terminals.ok && <ErrorNotice error={terminals.error} />}
        {terminals.ok && terminals.data.length === 0 && (
          <p className={styles.hint}>Nenhum terminal cadastrado.</p>
        )}
        {terminals.ok && terminals.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Terminal</th>
                  <th>Situação</th>
                  <th>Conexão</th>
                  <th>Versão</th>
                  <th>Sincronização</th>
                  <th>Ações</th>
                </tr>
              </thead>
              <tbody>
                {terminals.data.map((terminal) => (
                  <tr key={terminal.id}>
                    <td>{terminal.branch_name}</td>
                    <td>
                      <strong>
                        {terminal.number && `${terminal.number} · `}
                        {terminal.name ?? "Sem nome"}
                      </strong>
                      <small>
                        {terminal.profile && PROFILE_LABELS[terminal.profile]}
                        {terminal.profile && terminal.device_name && " · "}
                        {terminal.device_name}
                      </small>
                      {seriesOf(terminal.id) && <small>{seriesOf(terminal.id)}</small>}
                      {terminal.key_storage === "file" && (
                        <small className={styles.warning}>
                          Chave em arquivo (proteção menor)
                        </small>
                      )}
                    </td>
                    <td>
                      <span className={`${styles.badge} ${styles[terminal.status]}`}>
                        {STATUS_LABELS[terminal.status]}
                      </span>
                    </td>
                    <td>
                      <span
                        className={`${styles.badge} ${styles[terminal.connectivity]}`}
                      >
                        {terminal.connectivity === "online" ? "Online" : "Offline"}
                      </span>
                      <small>Visto: {formatDate(terminal.last_seen_at)}</small>
                    </td>
                    <td>{terminal.app_version ?? "-"}</td>
                    <td>
                      <SyncSummary terminal={terminal} />
                    </td>
                    <td className={styles.actions}>
                      {terminal.status === "pending" && canApprove && (
                        <>
                          <ApproveForm id={terminal.id} />
                          <ReasonAction
                            id={terminal.id}
                            action="revoke"
                            label="Recusar"
                          />
                        </>
                      )}
                      {terminal.status === "active" && (
                        <>
                          {canBlock && <ReasonAction id={terminal.id} action="block" />}
                          {canRevoke && <ReasonAction id={terminal.id} action="revoke" />}
                        </>
                      )}
                      {terminal.status === "blocked" && (
                        <>
                          {canBlock && <UnblockButton id={terminal.id} />}
                          {canRevoke && <ReasonAction id={terminal.id} action="revoke" />}
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>}
    </>
  );
}
