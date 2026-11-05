import type { Metadata } from "next";
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
const NOT_AVAILABLE = "Ainda não disponível";

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
                  <th>Último sync</th>
                  <th>Pendências</th>
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
                      {terminal.last_sync_at
                        ? formatDate(terminal.last_sync_at)
                        : NOT_AVAILABLE}
                    </td>
                    <td>{terminal.outbox_pending ?? NOT_AVAILABLE}</td>
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
