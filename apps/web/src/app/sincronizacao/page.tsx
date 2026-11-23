import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { getError } from "@farmaerp/error-catalog";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { ResolveForm } from "./ui";

export const metadata: Metadata = { title: "Sincronização · FarmaERP" };

interface ConflictRow {
  id: string;
  branch_name: string;
  terminal_name: string;
  kind: string;
  error_code: string;
  payload: Record<string, unknown>;
  status: "open" | "resolved";
  created_at: string;
  resolved_at: string | null;
  resolved_by_name: string | null;
  resolution_note: string | null;
  can_resolve: boolean;
}

const KINDS: Record<string, string> = {
  log: "Registro de aviso ou erro do PDV",
  sale: "Venda",
  cash_session_open: "Abertura de turno",
};
const STATUS = { abertos: "open", resolvidos: "resolved", todos: "all" } as const;
type StatusKey = keyof typeof STATUS;
type SearchParams = Promise<{ situacao?: string }>;

const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

export default function SyncPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando a sincronização...</p>}>
        <SyncContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SyncContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/sincronizacao");
  if (!can(user, "sync.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Sincronização</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os conflitos de sincronização.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const statusKey: StatusKey = params.situacao && params.situacao in STATUS ? (params.situacao as StatusKey) : "abertos";
  const result = await apiFetch<ConflictRow[]>(`/admin/sync/conflicts?status=${STATUS[statusKey]}`);
  if (!result.ok) redirectIfNeeded(result.error, "/sincronizacao");

  return (
    <>
      <AppHeader user={user} />
      <h1>Sincronização</h1>
      <section className={styles.card}>
        <h2>Conflitos</h2>
        <p className={styles.hint}>
          O que os terminais enviaram e a central não pôde aceitar. Nada se perde: o registro fica aqui como chegou, e o
          terminal segue enviando o resto. Depois de entender o caso, marque como resolvido explicando o que foi feito. A
          situação de cada terminal fica em <Link href="/terminais">Terminais</Link>.
        </p>
        <nav className={styles.inline} aria-label="Situação">
          {(Object.keys(STATUS) as StatusKey[]).map((key) =>
            key === statusKey ? (
              <strong key={key}>{key[0].toUpperCase() + key.slice(1)}</strong>
            ) : (
              <Link key={key} href={`/sincronizacao?situacao=${key}`}>
                {key[0].toUpperCase() + key.slice(1)}
              </Link>
            ),
          )}
        </nav>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && result.data.length === 0 && (
          <p className={styles.hint}>
            {statusKey === "abertos" ? "Nenhum conflito aberto. Está tudo sincronizado." : "Nenhum conflito nesta lista."}
          </p>
        )}
        {result.ok && result.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Filial e terminal</th>
                  <th>O que chegou</th>
                  <th>Motivo</th>
                  <th>Situação</th>
                </tr>
              </thead>
              <tbody>
                {result.data.map((row) => {
                  const reason = getError(row.error_code);
                  return (
                    <tr key={row.id}>
                      <td>{dateTimeText(row.created_at)}</td>
                      <td>
                        {row.branch_name}
                        <small className={styles.hint}> · {row.terminal_name}</small>
                      </td>
                      <td>
                        {KINDS[row.kind] ?? `Tipo "${row.kind}"`}
                        <details>
                          <summary>Ver conteúdo</summary>
                          <pre className={styles.payload}>{JSON.stringify(row.payload, null, 2)}</pre>
                        </details>
                      </td>
                      <td>
                        {reason.message}
                        <small className={styles.hint}>
                          {" "}
                          {reason.action} · Código {row.error_code}
                        </small>
                      </td>
                      <td>
                        {row.status === "open" ? (
                          row.can_resolve ? (
                            <ResolveForm id={row.id} />
                          ) : (
                            "Aberto"
                          )
                        ) : (
                          <>
                            Resolvido em {dateTimeText(row.resolved_at!)} por {row.resolved_by_name}
                            <small className={styles.hint}> · {row.resolution_note}</small>
                          </>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        {result.ok && result.data.length >= 200 && (
          <p className={styles.warning}>A lista mostra os 200 conflitos mais recentes.</p>
        )}
      </section>
    </>
  );
}
