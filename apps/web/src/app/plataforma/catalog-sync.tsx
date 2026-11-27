"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import { AutoRefresh } from "../importacoes/ui";
import styles from "../terminais/page.module.css";
import own from "./catalog-sync.module.css";
import { type CatalogSyncState, runCatalogSync } from "./actions";

export interface CatalogSyncRun {
  id: string;
  trigger: "schedule" | "manual";
  status: "running" | "unchanged" | "updated" | "failed";
  startedAt: string;
  finishedAt: string | null;
  items: number | null;
  changed: number | null;
  failed: number | null;
  removed: number | null;
  message: string | null;
}

export interface CatalogSyncStatus {
  configured: boolean;
  items: number;
  pending: number;
  removed: number;
  imagesDue: number;
  runs: CatalogSyncRun[];
}

const STATUS: Record<CatalogSyncRun["status"], string> = {
  running: "Em andamento",
  unchanged: "Sem mudanças",
  updated: "Atualizada",
  failed: "Falhou",
};
const number = (value: number | null) => (value ?? 0).toLocaleString("pt-BR");
const when = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short" });

/** Cópia do Catálogo externo: números, últimas cópias e "Atualizar agora". */
export function CatalogSyncPanel({ status }: { status: CatalogSyncStatus }) {
  const [state, action, pending] = useActionState<CatalogSyncState>(runCatalogSync, {});
  const running = status.runs[0]?.status === "running";
  const lastGood = status.runs.find((run) => run.status === "updated" || run.status === "unchanged");
  return (
    <>
      {running && <AutoRefresh />}
      <section className={styles.card}>
        <h2>Cópia do Catálogo</h2>
        {!status.configured ? (
          <p className={styles.warning}>
            A ligação com o Catálogo não está configurada. Informe o endereço e a chave nas variáveis da API (CATALOG_URL
            e CATALOG_API_KEY) e publique de novo.
          </p>
        ) : (
          <p className={styles.hint}>
            A central copia o Catálogo de hora em hora; o código de barras que ainda não está na cópia é consultado na
            hora. {lastGood ? `Última cópia boa: ${when(lastGood.startedAt)}.` : "Ainda não houve cópia."}
          </p>
        )}
        <dl className={own.facts}>
          <div>
            <dt>Itens do Catálogo</dt>
            <dd>{number(status.items)}</dd>
          </div>
          <div>
            <dt>Pendentes no Catálogo</dt>
            <dd>{number(status.pending)}</dd>
          </div>
          <div>
            <dt>Saíram do Catálogo</dt>
            <dd>{number(status.removed)}</dd>
          </div>
          <div>
            <dt>Imagens a trazer</dt>
            <dd>{number(status.imagesDue)}</dd>
          </div>
        </dl>
        {status.configured && (
          <form action={action}>
            <button type="submit" disabled={pending || running}>
              {running ? "Cópia em andamento..." : pending ? "Começando..." : "Atualizar agora"}
            </button>
          </form>
        )}
        {state.started && !running && <p className={styles.hint}>Cópia iniciada. A situação aparece abaixo.</p>}
        <ErrorNotice error={state.error} />
      </section>
      <section className={styles.card}>
        <h2>Últimas cópias</h2>
        {status.runs.length === 0 ? (
          <p className={styles.hint}>Nenhuma cópia ainda.</p>
        ) : (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Início</th>
                  <th>Origem</th>
                  <th>Situação</th>
                  <th>Itens</th>
                  <th>Gravados</th>
                  <th>Recusados</th>
                  <th>Saíram</th>
                </tr>
              </thead>
              <tbody>
                {status.runs.map((run) => (
                  <tr key={run.id}>
                    <td>{when(run.startedAt)}</td>
                    <td>{run.trigger === "manual" ? "Atualizar agora" : "Automática"}</td>
                    <td>
                      <span className={run.status === "failed" ? styles.warning : undefined}>{STATUS[run.status]}</span>
                      {run.message && <small className={styles.hint}>{run.message}</small>}
                    </td>
                    <td>{run.status === "updated" ? number(run.items) : "—"}</td>
                    <td>{run.status === "updated" ? number(run.changed) : "—"}</td>
                    <td>{run.status === "updated" ? number(run.failed) : "—"}</td>
                    <td>{run.status === "updated" ? number(run.removed) : "—"}</td>
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
