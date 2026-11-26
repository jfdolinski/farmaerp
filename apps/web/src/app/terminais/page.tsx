import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import {
  AddTerminal,
  ApproveForm,
  OfflineMinutesForm,
  SaleSettingsForm,
  ProfileForm,
  UpdateRingForm,
  ReturnDaysForm,
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
  offline_minutes: number | null;
  branch_offline_minutes: number;
  update_ring: "test" | "general";
  last_update_status: "downloaded" | "applied" | "rolled_back" | "failed" | null;
  last_update_version: string | null;
  last_update_at: string | null;
  last_update_detail: string | null;
}

const UPDATE_LABELS: Record<string, string> = {
  downloaded: "baixada, aplica no próximo fechamento ou abertura",
  applied: "aplicada",
  rolled_back: "voltou à versão anterior",
  failed: "falhou",
};

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
  const canStructure = can(user, "structure.manage");
  const [terminals, branches] = await Promise.all([
    apiFetch<MonitorRow[]>("/admin/terminals"),
    apiFetch<{ id: string; name: string; offline_zero_stock_minutes: number; quote_validity_days: number; seller_pin_required: boolean; return_days: number }[]>("/admin/branches"),
  ]);

  if (!terminals.ok) redirectIfNeeded(terminals.error, "/terminais");

  return (
    <>
      <AppHeader user={user} />
      <h1>Terminais</h1>

      {canRequest && <AddTerminal branches={branches.ok ? branches.data : []} />}

      {canStructure && branches.ok && branches.data.length > 0 && (
        <section className={styles.card}>
          <h2>Venda sem estoque com o PDV sem internet</h2>
          <p className={styles.hint}>
            Tempo mínimo sem sincronizar para o PDV aceitar vender um produto com o saldo local zerado, sempre com a
            autorização do gerente. Cada terminal pode ter uma exceção, na tabela abaixo.
          </p>
          <ul className={styles.bullets}>
            {branches.data.map((branch) => (
              <li key={branch.id}>
                <strong>{branch.name}</strong>{" "}
                <OfflineMinutesForm scope="branch" id={branch.id} current={branch.offline_zero_stock_minutes} />
              </li>
            ))}
          </ul>
        </section>
      )}

      {canStructure && branches.ok && branches.data.length > 0 && (
        <section className={styles.card}>
          <h2>Orçamento, vendedor e devolução</h2>
          <p className={styles.hint}>
            Por quanto tempo o orçamento vale no caixa, se o vendedor digita o PIN junto com o código e o prazo de devolução.
          </p>
          <ul className={styles.bullets}>
            {branches.data.map((branch) => (
              <li key={branch.id}>
                <strong>{branch.name}</strong>{" "}
                <SaleSettingsForm id={branch.id} days={branch.quote_validity_days} pin={branch.seller_pin_required} />{" "}
                <ReturnDaysForm id={branch.id} days={branch.return_days} />
              </li>
            ))}
          </ul>
        </section>
      )}

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
                    <td>
                      {terminal.app_version ?? "-"}
                      {terminal.update_ring === "test" && <small>Terminal de teste</small>}
                      {terminal.last_update_status && (
                        <small className={terminal.last_update_status === "rolled_back" || terminal.last_update_status === "failed" ? styles.warning : undefined}>
                          {terminal.last_update_version}: {UPDATE_LABELS[terminal.last_update_status]} em {formatDate(terminal.last_update_at)}
                          {terminal.last_update_detail ? ` (${terminal.last_update_detail})` : ""}
                        </small>
                      )}
                    </td>
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
                      {(terminal.status === "active" || terminal.status === "blocked") && canApprove && terminal.profile && (
                        <ProfileForm id={terminal.id} current={terminal.profile} />
                      )}
                      {(terminal.status === "active" || terminal.status === "blocked") && canApprove && (
                        <UpdateRingForm id={terminal.id} current={terminal.update_ring} />
                      )}
                      {terminal.status === "active" && canApprove && (
                        <OfflineMinutesForm
                          scope="terminal"
                          id={terminal.id}
                          current={terminal.offline_minutes}
                          inherited={terminal.branch_offline_minutes}
                        />
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
