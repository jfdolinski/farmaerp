import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { count, fileSize, type ImportRow, moment, RUNNING, STATUS_LABELS } from "./labels";
import { AutoRefresh, ImportUploader } from "./ui";

export const metadata: Metadata = { title: "Importação de notas · FarmaERP" };

export default function ImportsPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando importações...</p>}>
        <ImportsContent />
      </Suspense>
    </main>
  );
}

async function ImportsContent() {
  const user = await requireUser("/importacoes");
  if (!can(user, "imports.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Importação de notas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para importar notas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ImportRow[]>("/admin/imports");
  if (!result.ok) redirectIfNeeded(result.error, "/importacoes");
  const rows = result.ok ? result.data : [];

  return (
    <>
      <AppHeader user={user} />
      {rows.some((row) => RUNNING.has(row.status)) && <AutoRefresh />}
      <h1>Importação de notas</h1>
      <p className={styles.hint}>
        Traga as notas já emitidas pelo sistema anterior num arquivo .zip com os XML (pode ter pastas). Nesta etapa
        entram as NFC-e autorizadas: a filial é cadastrada pelo CNPJ do emitente, os produtos pelo código do sistema
        anterior, os clientes pelo CPF ou CNPJ, e cada venda baixa o estoque na data da nota. Notas canceladas desfazem
        a venda. Enviar o mesmo arquivo de novo é seguro: notas repetidas são ignoradas.
      </p>
      <section className={styles.card}>
        <h2>Enviar arquivo</h2>
        <ImportUploader />
      </section>
      <section className={styles.card}>
        <h2>Arquivos enviados</h2>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && rows.length === 0 && <p className={styles.hint}>Nenhum arquivo enviado ainda.</p>}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Arquivo</th>
                  <th>Enviado em</th>
                  <th>Situação</th>
                  <th>Importadas</th>
                  <th>Repetidas</th>
                  <th>Ignoradas</th>
                  <th>Com problema</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      {row.file_name}
                      <br />
                      <small>{fileSize(row.size_bytes)}</small>
                    </td>
                    <td>{moment(row.created_at)}</td>
                    <td>{STATUS_LABELS[row.status] ?? row.status}</td>
                    <td>{count(row.totals?.imported)}</td>
                    <td>{count(row.totals?.duplicate)}</td>
                    <td>{count(row.totals?.ignored)}</td>
                    <td>{count(row.totals?.failed)}</td>
                    <td>
                      <Link href={`/importacoes/${row.id}`}>Ver relatório</Link>
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
