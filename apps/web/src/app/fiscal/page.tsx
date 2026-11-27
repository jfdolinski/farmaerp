import type { Metadata } from "next";
import { getError } from "@farmaerp/error-catalog";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../shell/tabs";
import { CatalogKeyForm, type CatalogKeyRow } from "./catalog-keys";
import { ReturnTaxForm, type ReturnTaxRow } from "./return-tax";
import {
  CertificateForm,
  CopyCertificateForm,
  CscForm,
  DfeToggle,
  FiscalRow,
  NfceForm,
  NfceRow,
  RegimeForm,
  SeriesForm,
  SeriesRow,
  StateRegistrationForm,
} from "./ui";

export const metadata: Metadata = { title: "Fiscal · FarmaERP" };

type SearchParams = Promise<{ aba?: string | string[] }>;

const TABS: TabItem[] = [
  { id: "empresa", label: "Regime e inscrição" },
  { id: "certificado", label: "Certificado" },
  { id: "download", label: "Download de notas" },
  { id: "nfce", label: "NFC-e" },
  { id: "tributacao", label: "Tributação" },
  { id: "series", label: "Séries" },
  { id: "devolucao", label: "NF-e de devolução e transferência" },
  { id: "catalogo", label: "Catálogo" },
];

export default function FiscalPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando configuração fiscal...</p>}>
        <FiscalContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function FiscalContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/fiscal");

  if (!["fiscal.view", "fiscal.manage", "fiscal.certificate"].some((code) => can(user, code))) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Fiscal</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver a configuração fiscal.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<FiscalRow[]>("/admin/fiscal");
  if (!result.ok) redirectIfNeeded(result.error, "/fiscal");
  const rows = result.ok ? result.data : [];
  const tab = activeTab(TABS, (await searchParams).aba);
  const [series, coverage, dfe, nfce] = await Promise.all([
    tab === "series" ? apiFetch<SeriesRow[]>("/admin/fiscal/series") : null,
    tab === "tributacao" ? apiFetch<CoverageRow[]>("/admin/fiscal/tax-coverage") : null,
    tab === "download" ? apiFetch<DfeRow[]>("/admin/dfe/status") : null,
    tab === "nfce" ? apiFetch<NfceRow[]>("/admin/fiscal/nfce") : null,
  ]);
  const returnTax = tab === "devolucao" ? await apiFetch<ReturnTaxRow[]>("/admin/fiscal/return-tax") : null;
  // Problemas da tributação do Catálogo, só das filiais que têm algum.
  const problemBranches = coverage?.ok ? coverage.data.filter((item) => Number(item.catalog_problems) > 0) : [];
  const problems = new Map(
    await Promise.all(
      problemBranches.map(async (item) => {
        const list = await apiFetch<CatalogTaxProblem[]>(`/admin/fiscal/branches/${encodeURIComponent(item.branch_id)}/catalog-tax-problems`);
        return [item.branch_id, list.ok ? list.data : []] as const;
      }),
    ),
  );
  const catalogKeys =
    tab === "catalogo" ? await apiFetch<{ configured: boolean; branches: CatalogKeyRow[] }>("/admin/catalog-keys") : null;
  const companies = [...new Set(rows.map((row) => row.company_id))];

  return (
    <>
      <AppHeader user={user} />
      <h1>Fiscal</h1>
      <Tabs base="/fiscal" items={TABS} active={tab}>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && rows.length === 0 && (
          <section className={styles.card}>
            <p className={styles.hint}>Nenhuma filial disponível para você.</p>
          </section>
        )}
        {returnTax && (
          <>
            <p className={styles.hint}>
              CFOP e situação tributária das NF-e emitidas pela central. A devolução ao fornecedor é um espelho da
              compra (ICMS, ST e IPI vêm da nota original); a transferência entre filiais vai pelo custo médio da
              origem, e o ICMS e o PIS/COFINS seguem os mesmos códigos abaixo. Confira estes padrões com o contador
              antes de usar em produção.
            </p>
            {!returnTax.ok && <ErrorNotice error={returnTax.error} />}
            {returnTax.ok &&
              returnTax.data.map((row) => (
                <section key={row.branch_id} className={styles.card}>
                  <h2>{row.branch_name}</h2>
                  {row.customized && <p className={styles.hint}>Padrões alterados para esta filial.</p>}
                  <ReturnTaxForm row={row} />
                </section>
              ))}
          </>
        )}
        {catalogKeys && (
          <>
            <p className={styles.hint}>
              Cada filial é uma empresa no Catálogo, com a própria chave: a filial consulta o Catálogo e recebe a
              tributação da UF dela com essa chave, e as consultas contam na cobrança dela. Gere a chave no Catálogo, em
              Empresas, e cole aqui; ela é conferida no Catálogo antes de ser salva.
            </p>
            {!catalogKeys.ok && <ErrorNotice error={catalogKeys.error} />}
            {catalogKeys.ok && !catalogKeys.data.configured && (
              <p className={styles.warning}>
                A ligação com o Catálogo ainda não está ligada no servidor (falta o endereço do Catálogo na API).
              </p>
            )}
            {catalogKeys.ok &&
              catalogKeys.data.branches.map((row) => (
                <section key={row.branch_id} className={styles.card}>
                  <h2>
                    {row.branch_name}
                    <small className={styles.hint}> · {row.company_name}</small>
                  </h2>
                  <CatalogKeyForm row={row} />
                </section>
              ))}
          </>
        )}
        {tab !== "devolucao" && tab !== "catalogo" &&
          companies.map((companyId) => {
            const branches = rows.filter((row) => row.company_id === companyId);
            return (
              <div key={companyId} className={styles.stack}>
                {tab === "empresa" && (
                  <section className={styles.card}>
                    <h2>{branches[0].company_name}</h2>
                    <RegimeForm row={branches[0]} />
                  </section>
                )}
                {branches.map((row) => (
                  <section key={row.branch_id} className={styles.card}>
                    <h2>{row.branch_name}</h2>
                    <p className={styles.hint}>CNPJ {row.branch_cnpj}</p>
                    {tab === "empresa" && <StateRegistrationForm row={row} />}
                    {tab === "certificado" && (
                      <>
                        <CertificateForm row={row} />
                        <CopyCertificateForm
                          row={row}
                          targets={branches.filter(
                            (target) =>
                              target.branch_id !== row.branch_id &&
                              target.can_certificate &&
                              target.branch_cnpj.slice(0, 8) === row.certificate_cnpj?.slice(0, 8),
                          )}
                        />
                      </>
                    )}
                    {dfe &&
                      (dfe.ok ? (
                        <DfeStatus
                          row={dfe.data.find((item) => item.branch_id === row.branch_id)}
                          branchId={row.branch_id}
                        />
                      ) : (
                        <ErrorNotice error={dfe.error} />
                      ))}
                    {nfce && (
                      <>
                        <h3>CSC da NFC-e</h3>
                        <CscForm row={row} />
                        <h3>Emitir NFC-e</h3>
                        {nfce.ok ? (
                          (() => {
                            const item = nfce.data.find((entry) => entry.branch_id === row.branch_id);
                            return item ? <NfceForm row={item} /> : null;
                          })()
                        ) : (
                          <ErrorNotice error={nfce.error} />
                        )}
                      </>
                    )}
                    {coverage &&
                      (coverage.ok ? (
                        <TaxCoverage
                          row={row}
                          coverage={coverage.data.find((item) => item.branch_id === row.branch_id)}
                          problems={problems.get(row.branch_id)}
                        />
                      ) : (
                        <ErrorNotice error={coverage.error} />
                      ))}
                    {series &&
                      (series.ok ? (
                        <BranchSeries rows={series.data.filter((item) => item.branch_id === row.branch_id)} />
                      ) : (
                        <ErrorNotice error={series.error} />
                      ))}
                  </section>
                ))}
              </div>
            );
          })}
        {tab !== "devolucao" && tab !== "catalogo" && (
          <p className={styles.hint}>
            O arquivo, a senha e o código CSC ficam criptografados no servidor e não voltam para a tela.
          </p>
        )}
      </Tabs>
    </>
  );
}

interface DfeRow {
  branch_id: string;
  enabled: boolean;
  has_certificate: boolean;
  last_run_at: string | null;
  next_run_at: string | null;
  last_status: string | null;
  last_message: string | null;
  last_error: string | null;
  waiting_awareness: string;
  can_manage: boolean;
  nfse_last_run_at: string | null;
  nfse_next_run_at: string | null;
  nfse_last_status: string | null;
  nfse_last_message: string | null;
  nfse_last_error: string | null;
}

/** Situação do ADN em português. */
const NFSE_STATUS: Record<string, string> = {
  DOCUMENTOS_LOCALIZADOS: "Notas recebidas",
  NENHUM_DOCUMENTO_LOCALIZADO: "Nenhuma nota nova",
  REJEICAO: "Consulta recusada",
};

const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

/** Situação do download da filial: o que aconteceu na última busca e quando vem a próxima. */
function DfeStatus({ row, branchId }: { row?: DfeRow; branchId: string }) {
  if (!row) return null;
  const waiting = Number(row.waiting_awareness);
  return (
    <>
      <p className={styles.hint}>
        A cada hora, a filial busca na Sefaz as notas emitidas para o CNPJ dela. As notas chegam primeiro como resumo,
        em Notas, esperando a ciência; depois da ciência, o XML completo chega sozinho. Em produção, uma nota só é
        lançada depois de confirmada pela Sefaz. As notas de serviço (NFS-e) chegam completas do Ambiente Nacional, em
        Notas de serviço.
      </p>
      {!row.has_certificate && (
        <p className={styles.warning}>Sem certificado digital válido: o download não funciona até enviar um.</p>
      )}
      {row.enabled ? (
        <p>
          <strong>Ligado.</strong>{" "}
          {row.last_run_at
            ? `Última busca em ${dateTimeText(row.last_run_at)}.`
            : "A primeira busca começa em até um minuto."}{" "}
          {row.last_run_at && row.next_run_at && `Próxima a partir de ${dateTimeText(row.next_run_at)}.`}
        </p>
      ) : (
        <p>
          <strong>Desligado.</strong>
        </p>
      )}
      {row.enabled && row.last_error && (
        <p className={styles.warning}>
          {getError(row.last_error).message}{" "}
          {row.last_message ? `Sefaz: ${row.last_message}` : getError(row.last_error).action}
        </p>
      )}
      {row.enabled && !row.last_error && row.last_message && (
        <p className={styles.hint}>Resposta da Sefaz: {row.last_message}</p>
      )}
      {row.enabled && row.nfse_last_run_at && (
        <p className={row.nfse_last_error ? styles.warning : styles.hint}>
          NFS-e: última busca em {dateTimeText(row.nfse_last_run_at)}
          {row.nfse_last_status && ` · ${NFSE_STATUS[row.nfse_last_status] ?? row.nfse_last_status}`}
          {row.nfse_last_error && ` · ${getError(row.nfse_last_error).message}`}
          {row.nfse_last_message && ` · Ambiente Nacional: ${row.nfse_last_message}`}
          {row.nfse_next_run_at && `. Próxima a partir de ${dateTimeText(row.nfse_next_run_at)}.`}
        </p>
      )}
      {waiting > 0 && (
        <p>
          <Link href="/notas?aba=ciencia">
            {waiting === 1
              ? "1 nota aguardando ciência"
              : `${waiting.toLocaleString("pt-BR")} notas aguardando ciência`}
          </Link>
        </p>
      )}
      {row.can_manage && <DfeToggle branchId={branchId} enabled={row.enabled} />}
    </>
  );
}

interface CoverageRow {
  branch_id: string;
  products_total: string;
  products_missing: string;
  catalog_waiting: string;
  catalog_problems: string;
  has_catalog_key: boolean;
}

interface CatalogTaxProblem {
  product_id: string;
  product_code: string;
  product_name: string;
  status: "no_rule" | "incomplete" | "not_found" | "failed";
  message: string | null;
  fetched_at: string;
}

const PROBLEM_LABELS: Record<CatalogTaxProblem["status"], string> = {
  no_rule: "Sem regra no Catálogo",
  incomplete: "Regra incompleta",
  not_found: "Fora do Catálogo",
  failed: "Catálogo sem resposta",
};

function TaxCoverage({
  row,
  coverage,
  problems,
}: {
  row: FiscalRow;
  coverage?: CoverageRow;
  problems?: CatalogTaxProblem[];
}) {
  const total = Number(coverage?.products_total ?? 0);
  const missing = Number(coverage?.products_missing ?? 0);
  const waiting = Number(coverage?.catalog_waiting ?? 0);
  return (
    <>
      {row.tax_regime === null && (
        <p className={styles.warning}>Informe o regime da empresa: sem ele, nenhum produto tem tributação.</p>
      )}
      {!row.state && (
        <p className={styles.warning}>
          Informe o estado da filial em <Link href="/empresas">Empresas e filiais</Link>: sem ele, nenhum produto tem
          tributação.
        </p>
      )}
      {total === 0 && <p className={styles.hint}>Nenhum produto ativo nesta filial.</p>}
      {total > 0 && missing === 0 && (
        <p className={styles.hint}>
          {total === 1
            ? "O único produto ativo tem tributação."
            : `Todos os ${total.toLocaleString("pt-BR")} produtos ativos têm tributação.`}
        </p>
      )}
      {missing > 0 && (
        <p className={styles.warning}>
          Produtos ativos sem tributação: {missing.toLocaleString("pt-BR")} de {total.toLocaleString("pt-BR")}. Eles
          dependem do vínculo com o Catálogo e de uma regra para o regime e o estado desta filial.
        </p>
      )}
      {coverage && !coverage.has_catalog_key && (
        <p className={styles.warning}>
          Esta filial não tem chave do Catálogo: a tributação do Catálogo não é buscada para ela. Cadastre na aba{" "}
          <Link href="/fiscal?aba=catalogo">Catálogo</Link>.
        </p>
      )}
      {coverage?.has_catalog_key && waiting > 0 && (
        <p className={styles.hint}>
          Aguardando a primeira busca no Catálogo: {waiting.toLocaleString("pt-BR")} produto(s). A tributação é buscada
          aos poucos, e renovada todo dia.
        </p>
      )}
      {problems && problems.length > 0 && (
        <details>
          <summary className={styles.warning}>
            Tributação do Catálogo com problema: {Number(coverage?.catalog_problems ?? problems.length).toLocaleString("pt-BR")}{" "}
            produto(s)
          </summary>
          <p className={styles.hint}>
            O ajuste é feito no Catálogo (regra do NCM, classificação ou origem do produto). O código de ICMS do regime
            que o Catálogo não informa é convertido por uma tabela fixa, a conferir com o contador.
          </p>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Produto</th>
                  <th>Situação</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody>
                {problems.map((problem) => (
                  <tr key={problem.product_id}>
                    <td>
                      <Link href={`/produtos/${problem.product_id}`}>
                        {problem.product_code} · {problem.product_name}
                      </Link>
                    </td>
                    <td>{PROBLEM_LABELS[problem.status]}</td>
                    <td>{problem.message}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
      )}
    </>
  );
}

function BranchSeries({ rows }: { rows: SeriesRow[] }) {
  if (rows.length === 0) {
    return (
      <p className={styles.hint}>
        Nenhum terminal emissor nesta filial. As séries são criadas quando um terminal de caixa ou autoatendimento é
        aprovado.
      </p>
    );
  }
  return (
    <>
      {rows.map((row) => (
        <SeriesForm key={row.id} row={row} />
      ))}
      <p className={styles.hint}>
        Se a filial veio de outro sistema, informe o próximo número da série antiga. Depois da primeira nota, a série
        não muda mais.
      </p>
    </>
  );
}
