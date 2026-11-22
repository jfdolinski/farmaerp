import type { Metadata } from "next";
import { getError } from "@farmaerp/error-catalog";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import {
  CertificateForm,
  CopyCertificateForm,
  CscForm,
  DfeToggle,
  FiscalRow,
  RegimeForm,
  SeriesForm,
  SeriesRow,
  StateRegistrationForm,
} from "./ui";

export const metadata: Metadata = { title: "Fiscal · FarmaERP" };

export default function FiscalPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando configuração fiscal...</p>}>
        <FiscalContent />
      </Suspense>
    </main>
  );
}

async function FiscalContent() {
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
  const [series, coverage, dfe] = await Promise.all([
    apiFetch<SeriesRow[]>("/admin/fiscal/series"),
    apiFetch<CoverageRow[]>("/admin/fiscal/tax-coverage"),
    apiFetch<DfeRow[]>("/admin/dfe/status"),
  ]);
  const companies = [...new Set(rows.map((row) => row.company_id))];

  return (
    <>
      <AppHeader user={user} />
      <h1>Fiscal</h1>
      {!result.ok && <ErrorNotice error={result.error} />}
      {result.ok && rows.length === 0 && (
        <section className={styles.card}>
          <p className={styles.hint}>Nenhuma filial disponível para você.</p>
        </section>
      )}
      {companies.map((companyId) => {
        const branches = rows.filter((row) => row.company_id === companyId);
        return (
          <div key={companyId} className={styles.stack}>
            <section className={styles.card}>
              <h2>{branches[0].company_name}</h2>
              <RegimeForm row={branches[0]} />
            </section>
            {branches.map((row) => (
              <section key={row.branch_id} className={styles.card}>
                <h2>{row.branch_name}</h2>
                <p className={styles.hint}>CNPJ {row.branch_cnpj}</p>
                <StateRegistrationForm row={row} />
                <h3>Certificado digital</h3>
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
                <h3>Download automático das notas de compra</h3>
                {dfe.ok ? (
                  <DfeStatus row={dfe.data.find((item) => item.branch_id === row.branch_id)} branchId={row.branch_id} />
                ) : (
                  <ErrorNotice error={dfe.error} />
                )}
                <h3>CSC da NFC-e</h3>
                <CscForm row={row} />
                <h3>Tributação</h3>
                {coverage.ok ? (
                  <TaxCoverage row={row} coverage={coverage.data.find((item) => item.branch_id === row.branch_id)} />
                ) : (
                  <ErrorNotice error={coverage.error} />
                )}
                <h3>Séries</h3>
                {series.ok ? (
                  <BranchSeries rows={series.data.filter((item) => item.branch_id === row.branch_id)} />
                ) : (
                  <ErrorNotice error={series.error} />
                )}
              </section>
            ))}
          </div>
        );
      })}
      <p className={styles.hint}>
        O arquivo, a senha e o código CSC ficam criptografados no servidor e não voltam para a tela.
      </p>
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
}

const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

/** Situação do download da filial: o que aconteceu na última busca e quando vem a próxima. */
function DfeStatus({ row, branchId }: { row?: DfeRow; branchId: string }) {
  if (!row) return null;
  const waiting = Number(row.waiting_awareness);
  return (
    <>
      <p className={styles.hint}>
        A cada hora, a filial busca na Sefaz as notas emitidas para o CNPJ dela. As notas chegam primeiro como resumo, em
        Notas, esperando a ciência; depois da ciência, o XML completo chega sozinho. Em produção, uma nota só é lançada
        depois de confirmada pela Sefaz.
      </p>
      {!row.has_certificate && (
        <p className={styles.warning}>Sem certificado digital válido: o download não funciona até enviar um.</p>
      )}
      {row.enabled ? (
        <p>
          <strong>Ligado.</strong>{" "}
          {row.last_run_at ? `Última busca em ${dateTimeText(row.last_run_at)}.` : "A primeira busca começa em até um minuto."}{" "}
          {row.last_run_at && row.next_run_at && `Próxima a partir de ${dateTimeText(row.next_run_at)}.`}
        </p>
      ) : (
        <p>
          <strong>Desligado.</strong>
        </p>
      )}
      {row.enabled && row.last_error && (
        <p className={styles.warning}>
          {getError(row.last_error).message} {row.last_message ? `Sefaz: ${row.last_message}` : getError(row.last_error).action}
        </p>
      )}
      {row.enabled && !row.last_error && row.last_message && (
        <p className={styles.hint}>Resposta da Sefaz: {row.last_message}</p>
      )}
      {waiting > 0 && (
        <p>
          <Link href="/notas">
            {waiting === 1 ? "1 nota aguardando ciência" : `${waiting.toLocaleString("pt-BR")} notas aguardando ciência`}
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
}

function TaxCoverage({ row, coverage }: { row: FiscalRow; coverage?: CoverageRow }) {
  const total = Number(coverage?.products_total ?? 0);
  const missing = Number(coverage?.products_missing ?? 0);
  return (
    <>
      {row.tax_regime === null && (
        <p className={styles.warning}>Informe o regime da empresa: sem ele, nenhum produto tem tributação.</p>
      )}
      {!row.state && (
        <p className={styles.warning}>
          Informe o estado da filial em <Link href="/empresas">Empresas e filiais</Link>: sem ele, nenhum produto tem tributação.
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
          Produtos ativos sem tributação: {missing.toLocaleString("pt-BR")} de {total.toLocaleString("pt-BR")}. Eles dependem do vínculo com o Catálogo e de uma regra para o regime e o estado desta filial.
        </p>
      )}
    </>
  );
}

function BranchSeries({ rows }: { rows: SeriesRow[] }) {
  if (rows.length === 0) {
    return (
      <p className={styles.hint}>
        Nenhum terminal emissor nesta filial. As séries são criadas quando um terminal de caixa ou autoatendimento é aprovado.
      </p>
    );
  }
  return (
    <>
      {rows.map((row) => (
        <SeriesForm key={row.id} row={row} />
      ))}
      <p className={styles.hint}>
        Se a filial veio de outro sistema, informe o próximo número da série antiga. Depois da primeira nota, a série não muda mais.
      </p>
    </>
  );
}
