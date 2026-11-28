import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../../app-header";
import { ErrorNotice } from "../../../error-notice";
import styles from "../../../terminais/page.module.css";
import { dateTimeText } from "../../../vendas/labels";
import { CorrectionForm } from "../../form";

export const metadata: Metadata = { title: "Carta de correção · FarmaERP" };

interface Correction {
  id: string;
  sequence: number;
  correction: string;
  protocol: string;
  status_code: string;
  registered_at: string;
  requested_by: string | null;
}

interface CorrectionPage {
  kind: "sale" | "central";
  id: string;
  note_kind: string;
  model: string;
  status: string;
  series: number;
  number: number;
  access_key: string;
  authorized_at: string | null;
  count: number;
  can_send: boolean;
  corrections: Correction[];
}

const NOTE_LABELS: Record<string, string> = {
  sale: "NF-e de venda",
  supplier_return: "NF-e de devolução ao fornecedor",
  transfer: "NF-e de transferência",
};

const STATUS_LABELS: Record<string, string> = {
  authorized: "autorizada",
  canceled: "cancelada",
  pending: "pendente na Sefaz",
  rejected: "recusada pela Sefaz",
  contingency: "em contingência",
};

/** Volta só para uma página da própria retaguarda. */
const backOf = (value: string | undefined) => (value && value.startsWith("/") && !value.startsWith("//") ? value : "/notas-fiscais");

const groups = (key: string) => key.replace(/(.{4})/g, "$1 ").trim();

export default function CorrectionPage({
  params,
  searchParams,
}: {
  params: Promise<{ kind: string; id: string }>;
  searchParams: Promise<{ voltar?: string }>;
}) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando as cartas de correção...</p>}>
        <CorrectionContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function CorrectionContent({
  params,
  searchParams,
}: {
  params: Promise<{ kind: string; id: string }>;
  searchParams: Promise<{ voltar?: string }>;
}) {
  const [{ kind: rawKind, id }, { voltar }] = await Promise.all([params, searchParams]);
  const kind = rawKind === "central" ? "central" : "sale";
  const back = backOf(voltar);
  const user = await requireUser(`/nfe-correcao/${kind}/${encodeURIComponent(id)}`);
  const result = await apiFetch<CorrectionPage>(`/admin/nfe-corrections/${kind}/${encodeURIComponent(id)}`);
  if (!result.ok) redirectIfNeeded(result.error, `/nfe-correcao/${kind}/${encodeURIComponent(id)}`);
  const note = result.ok ? result.data : null;
  const last = note?.corrections[0] ?? null;

  return (
    <>
      <AppHeader user={user} />
      <h1>Carta de correção</h1>
      <p>
        <Link href={back}>Voltar</Link>
      </p>
      {!result.ok && <ErrorNotice error={result.error} />}
      {note && (
        <>
          <section className={styles.card}>
            <h2>
              {NOTE_LABELS[note.note_kind] ?? "NF-e"} nº {note.number} série {note.series}
            </h2>
            <p>
              Chave <strong>{groups(note.access_key)}</strong>
            </p>
            <p className={styles.hint}>
              Situação: {STATUS_LABELS[note.status] ?? note.status}
              {note.authorized_at && ` desde ${dateTimeText(note.authorized_at)}`} · {note.count} de 20 cartas usadas
            </p>
          </section>

          <section className={styles.card}>
            <h2>Nova carta</h2>
            {note.can_send && <CorrectionForm kind={kind} id={note.id} last={last?.correction ?? null} />}
            {!note.can_send && (
              <p className={styles.hint}>
                {note.model !== "55"
                  ? "A NFC-e não tem carta de correção."
                  : note.status !== "authorized"
                    ? "Só a NF-e autorizada recebe carta de correção."
                    : note.count >= 20
                      ? "Esta NF-e já tem 20 cartas, o limite da Sefaz."
                      : "Você não tem permissão para emitir NF-e nesta filial."}
              </p>
            )}
          </section>

          <section className={styles.card}>
            <h2>Cartas registradas</h2>
            {note.corrections.length === 0 && <p className={styles.hint}>Nenhuma carta de correção nesta nota.</p>}
            {note.corrections.length > 0 && (
              <>
                <p className={styles.hint}>A carta mais recente vale: ela substitui as anteriores.</p>
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Carta</th>
                        <th>Correção</th>
                        <th>Protocolo</th>
                        <th>Quando</th>
                        <th>Arquivos</th>
                      </tr>
                    </thead>
                    <tbody>
                      {note.corrections.map((row, index) => (
                        <tr key={row.id}>
                          <td>
                            {row.sequence}
                            {index === 0 && <small className={styles.hint}> · vale esta</small>}
                          </td>
                          <td>{row.correction}</td>
                          <td>
                            {row.protocol}
                            {row.status_code === "136" && <small className={styles.hint}> · registrada, aguardando vínculo à nota</small>}
                          </td>
                          <td>
                            {dateTimeText(row.registered_at)}
                            {row.requested_by && <small className={styles.hint}> · {row.requested_by}</small>}
                          </td>
                          <td>
                            <a href={`/nfe-correcao/arquivo/${row.id}/pdf`}>PDF</a> · <a href={`/nfe-correcao/arquivo/${row.id}/xml`}>XML</a>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </>
            )}
          </section>
        </>
      )}
    </>
  );
}
