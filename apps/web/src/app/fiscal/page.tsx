import type { Metadata } from "next";
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
  const [series, coverage] = await Promise.all([
    apiFetch<SeriesRow[]>("/admin/fiscal/series"),
    apiFetch<CoverageRow[]>("/admin/fiscal/tax-coverage"),
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
