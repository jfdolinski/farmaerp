import Link from "next/link";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { count, fileSize, formatCnpj, type ImportRow, MODEL_LABELS, moment, RUNNING, STATUS_LABELS } from "./labels";
import { AutoRefresh } from "./ui";

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
  ignored_reasons?: { reason: string; total: number }[];
  /** CNPJs desta importação que o cliente ainda não tem como filial. */
  waiting?: { cnpj: string; name: string | null; status: string; notes: number }[];
  /** Itens de NF-e sem produto cadastrado, que ficaram de fora (até 500). */
  skipped_items?: {
    note_number: number;
    access_key: string;
    line: number | null;
    code: string | null;
    name: string | null;
    gtin: string | null;
    quantity: number | null;
  }[];
  skipped_total?: number;
}

const WAITING_STATUS: Record<string, string> = {
  pending: "Aguardando a decisão",
  created: "Criada: as notas estão entrando",
  refused: "Recusada",
};

export type Params = Promise<{ id: string }>;

/**
 * Relatório de uma importação. Na Plataforma (`platform`), é o arquivo que o administrador da
 * plataforma enviou para um cliente.
 */
export async function ReportContent({ params, platform = false }: { params: Params; platform?: boolean }) {
  const { id } = await params;
  const base = platform ? "/plataforma/importacao" : "/importacoes";
  const back = platform ? "/plataforma?aba=importacao" : "/importacoes";
  const user = await requireUser(`${base}/${id}`);
  if (platform ? !user.platformAdmin : !can(user, "imports.manage")) {
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
  const result = await apiFetch<ImportReport>(
    `${platform ? "/platform/imports" : "/admin/imports"}/${encodeURIComponent(id)}`,
  );
  if (!result.ok) {
    redirectIfNeeded(result.error, `${base}/${id}`);
    return (
      <>
        <AppHeader user={user} />
        <h1>Relatório da importação</h1>
        <p>
          <Link href={back}>Voltar às importações</Link>
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
        <Link href={back}>Voltar às importações</Link>
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
            O envio não terminou ({fileSize(report.received_bytes)} de {fileSize(report.size_bytes)}). Envie o arquivo
            de novo pela tela de importação.
          </p>
        )}
        {RUNNING.has(report.status) && (
          <p className={styles.hint}>
            {report.status === "queued" ? "Aguardando a vez na fila." : "Processando as notas."} Esta tela se atualiza
            sozinha.
          </p>
        )}
        {report.error && <p className={styles.warning}>{report.error} Confira o arquivo e envie de novo.</p>}
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
                <th>Ignoradas (veja os motivos abaixo)</th>
                <td>{count(totals.ignored)}</td>
              </tr>
              <tr>
                <th>Com problema</th>
                <td>{count(totals.failed)}</td>
              </tr>
              {(totals.waiting ?? 0) > 0 && (
                <tr>
                  <th>Esperando o destino da empresa (veja abaixo)</th>
                  <td>{count(totals.waiting)}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        {models.length > 0 && (
          <p className={styles.hint}>
            Por tipo de documento:{" "}
            {models.map(([model, total]) => `${MODEL_LABELS[model] ?? `Modelo ${model}`}: ${count(total)}`).join(" · ")}
            . CT-e, SAT e outros documentos ainda não entram (ficam como ignorados).
          </p>
        )}
      </section>

      {(report.waiting ?? []).length > 0 && (
        <section className={styles.card}>
          <h2>Empresas ou filiais que ainda não estão cadastradas</h2>
          <p className={styles.hint}>
            As notas destes CNPJs esperam o administrador da plataforma definir a empresa ou a filial. Quando ele criar,
            elas entram sozinhas, sem enviar o arquivo de novo. Se ele recusar, ficam como ignoradas.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>CNPJ</th>
                  <th>Nome na nota</th>
                  <th>Situação</th>
                  <th>Notas</th>
                </tr>
              </thead>
              <tbody>
                {(report.waiting ?? []).map((row) => (
                  <tr key={row.cnpj}>
                    <td>{formatCnpj(row.cnpj)}</td>
                    <td>{row.name ?? "—"}</td>
                    <td>{WAITING_STATUS[row.status] ?? row.status}</td>
                    <td>{count(row.notes)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {(report.skipped_total ?? 0) > 0 && (
        <section className={styles.card}>
          <h2>Itens sem produto cadastrado</h2>
          <p className={styles.hint}>
            {count(report.skipped_total)} {report.skipped_total === 1 ? "item de NF-e ficou" : "itens de NF-e ficaram"}{" "}
            de fora: os produtos são cadastrados só pelas NFC-e importadas. O resto de cada nota entrou normalmente.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Nota</th>
                  <th>Item</th>
                  <th>Código</th>
                  <th>Descrição</th>
                  <th>Código de barras</th>
                  <th>Quantidade</th>
                </tr>
              </thead>
              <tbody>
                {(report.skipped_items ?? []).map((row) => (
                  <tr key={`${row.access_key}-${row.line ?? row.code}`}>
                    <td>{row.note_number.toLocaleString("pt-BR")}</td>
                    <td>{row.line ?? "—"}</td>
                    <td>{row.code ?? "—"}</td>
                    <td>{row.name ?? "—"}</td>
                    <td>{row.gtin ?? "—"}</td>
                    <td>{row.quantity === null ? "—" : Number(row.quantity).toLocaleString("pt-BR")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {(report.skipped_items ?? []).length === 500 && (
            <p className={styles.hint}>Mostrando os 500 primeiros itens.</p>
          )}
        </section>
      )}

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

      {(report.ignored_reasons ?? []).length > 0 && (
        <section className={styles.card}>
          <h2>Ignoradas, por motivo</h2>
          <p className={styles.hint}>
            Notas que não mexem em nada. Se aparecer &quot;Nenhuma filial do cliente&quot;, cadastre a empresa em
            Empresas (ou importe as NFC-e dela) e envie o arquivo de novo.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Motivo</th>
                  <th>Notas</th>
                </tr>
              </thead>
              <tbody>
                {(report.ignored_reasons ?? []).map((row) => (
                  <tr key={row.reason}>
                    <td>{row.reason}</td>
                    <td>{count(row.total)}</td>
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
