import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { BranchForm, BranchRow, CompanyForm, CompanyRow, CreateBranchForm, CreateCompanyForm, MoveBranchForm } from "./ui";

export const metadata: Metadata = { title: "Empresas · FarmaERP" };

interface Structure {
  canManage: boolean;
  companies: CompanyRow[];
  branches: BranchRow[];
}

export default function CompaniesPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando empresas...</p>}>
        <CompaniesContent />
      </Suspense>
    </main>
  );
}

async function CompaniesContent() {
  const user = await requireUser("/empresas");

  if (!can(user, "structure.manage") && !can(user, "branches.view_all")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Empresas e filiais</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as empresas e filiais.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<Structure>("/admin/structure");
  if (!result.ok) redirectIfNeeded(result.error, "/empresas");
  const data = result.ok ? result.data : { canManage: false, companies: [], branches: [] };

  return (
    <>
      <AppHeader user={user} />
      <h1>Empresas e filiais</h1>
      {!result.ok && <ErrorNotice error={result.error} />}
      {data.canManage && (
        <section className={styles.card}>
          <h2>Nova empresa da mesma rede</h2>
          <p className={styles.hint}>
            Outro CNPJ do mesmo dono: ele compartilha produtos, clientes, usuários e crediário com as empresas desta lista.
            Uma farmácia de outro dono é um cliente separado, cadastrado pelo administrador da plataforma.
          </p>
          <CreateCompanyForm />
        </section>
      )}
      {result.ok && data.companies.length === 0 && !data.canManage && (
        <section className={styles.card}>
          <p className={styles.hint}>Nenhuma empresa cadastrada.</p>
        </section>
      )}
      {data.companies.map((company) => (
        <section key={company.id} className={styles.card}>
          <h2>{company.trade_name}</h2>
          <CompanyForm company={company} canManage={data.canManage} />
          {data.branches
            .filter((branch) => branch.company_id === company.id)
            .map((branch) => (
              <div key={branch.id} className={styles.device}>
                <h3>{branch.name}</h3>
                <BranchForm branch={branch} companyRoot={company.cnpj_root} canManage={data.canManage} />
                {data.canManage && <MoveBranchForm branch={branch} companies={data.companies} />}
              </div>
            ))}
          {data.canManage && <CreateBranchForm company={company} />}
        </section>
      ))}
    </>
  );
}
