import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { count, fileSize, type ImportRow, MODEL_LABELS, moment, RUNNING, STATUS_LABELS } from "../labels";
import { AutoRefresh } from "../ui";

export const metadata: Metadata = { title: "Relatório da importação · FarmaERP" };

interface ImportReport extends ImportRow {
  problems: {
    entry_name: string;
    access_key: string | null;
    model: string | null;
    result: string;
    error_code: string | null;
    reason: string | null;
  }[];
  last_numbers: { branch_id: string; branch_name: string; model: string; series: number; last_number: number }[];
}

type Params = Promise<{ id: string }>;

export default function ImportReportPage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando relatório...</p>}>
        <ReportContent params={params} />
      </Suspense>
    </main>
  );
}

async function ReportContent({ params }: { params: Params }) {
  const { id } = await params;
  const user = await requireUser(`/importacoes/${id}`);
  if (!can(user, "imports.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Relatório da importação</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para importar notas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ImportReport>(`/admin/imports/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, `/importacoes/${id}`);
    return (
      <>
        <AppHeader user={user} />
        <h1>Relatório da importação</h1>
        <p>
          <Link href="/importacoes">Voltar às importações</Link>
        </p>
        <ErrorNotice error={result.error} />
      </>
    );
  }
  const report = result.data;
  const totals = report.totals ?? {};
  const models = Object.entries(totals.models ?? {});

  return (
    <>
      <AppHeader user={user} />
      {RUNNING.has(report.status) && <AutoRefresh />}
      <h1>Relatório da importação</h1>
      <p>
        <Link href="/importacoes">Voltar às importações</Link>
      </p>
      <section className={styles.card}>
        <h2>{report.file_name}</h2>
        <p>
          <strong>{STATUS_LABELS[report.status] ?? report.status}</strong> · {fileSize(report.size_bytes)} · enviado em{" "}
          {moment(report.created_at)}
          {report.finished_at && ` · concluído em ${moment(report.finished_at)}`}
        </p>
        {report.status === "uploading" && (
          <p className={styles.warning}>
            O envio não terminou ({fileSize(report.received_bytes)} de {fileSize(report.size_bytes)}). Envie o arquivo de
            novo pela tela de importação.
          </p>
        )}
        {RUNNING.has(report.status) && (
          <p className={styles.hint}>
            {report.status === "queued" ? "Aguardando a vez na fila." : "Processando as notas."} Esta tela se atualiza
            sozinha.
          </p>
        )}
        {report.error && (
          <p className={styles.warning}>
            {report.error} Confira o arquivo e envie de novo.
          </p>
        )}
        <div className={styles.tableWrap}>
          <table>
            <tbody>
              <tr>
                <th>Arquivos lidos no .zip</th>
                <td>{count(totals.entries)}</td>
              </tr>
              <tr>
                <th>Vendas importadas</th>
                <td>{count(totals.imported)}</td>
              </tr>
              <tr>
                <th>Repetidas (já importadas antes)</th>
                <td>{count(totals.duplicate)}</td>
              </tr>
              <tr>
                <th>Canceladas na Sefaz</th>
                <td>{count(totals.canceled)}</td>
              </tr>
              <tr>
                <th>Ignoradas (outros documentos, homologação ou não autorizadas)</th>
                <td>{count(totals.ignored)}</td>
              </tr>
              <tr>
                <th>Com problema</th>
                <td>{count(totals.failed)}</td>
              </tr>
            </tbody>
          </table>
        </div>
        {models.length > 0 && (
          <p className={styles.hint}>
            Por tipo de documento:{" "}
            {models.map(([model, total]) => `${MODEL_LABELS[model] ?? `Modelo ${model}`}: ${count(total)}`).join(" · ")}
            . As NF-e e os outros modelos entram nas próximas etapas da importação.
          </p>
        )}
      </section>

      {report.last_numbers.length > 0 && (
        <section className={styles.card}>
          <h2>Última numeração</h2>
          <p className={styles.hint}>
            Maior número importado por filial, modelo e série. Use para configurar a série do caixa e continuar sem
            repetir número.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Modelo</th>
                  <th>Série</th>
                  <th>Último número</th>
                </tr>
              </thead>
              <tbody>
                {report.last_numbers.map((row) => (
                  <tr key={`${row.branch_id}-${row.model}-${row.series}`}>
                    <td>{row.branch_name}</td>
                    <td>{MODEL_LABELS[row.model] ?? row.model}</td>
                    <td>{row.series}</td>
                    <td>{row.last_number.toLocaleString("pt-BR")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {report.problems.length > 0 && (
        <section className={styles.card}>
          <h2>Notas com problema</h2>
          <p className={styles.hint}>
            Estas notas não entraram. Corrija o que o motivo indica (por exemplo, a filial de outro cliente) e envie o
            arquivo de novo: as que já entraram serão ignoradas.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Arquivo no .zip</th>
                  <th>Chave</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody>
                {report.problems.map((row, index) => (
                  <tr key={`${row.entry_name}-${index}`}>
                    <td>{row.entry_name}</td>
                    <td>
                      <small>{row.access_key ?? "—"}</small>
                    </td>
                    <td>
                      {row.reason ?? "—"}
                      {row.error_code && <small> Código {row.error_code}</small>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {report.problems.length === 500 && <p className={styles.hint}>Mostrando os 500 primeiros problemas.</p>}
        </section>
      )}
    </>
  );
}
