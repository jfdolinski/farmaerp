import type { Metadata } from "next";
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
                    (target) => target.branch_id !== row.branch_id && target.can_certificate,
                  )}
                />
                <h3>CSC da NFC-e</h3>
                <CscForm row={row} />
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
