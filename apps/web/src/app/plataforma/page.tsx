import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { CreateTenantForm, IssuerDecision, type PendingIssuer } from "./ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Plataforma · FarmaERP" };

interface TenantRow {
  group_id: string;
  name: string;
  created_at: string;
  companies: { legal_name: string; trade_name: string; cnpj_root: string }[];
  branch_count: number;
  user_count: number;
  admin_email: string | null;
}

const dateText = (value: string) =>
  new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" });
const rootText = (root: string) => `${root.slice(0, 2)}.${root.slice(2, 5)}.${root.slice(5, 8)}`;
const formatCnpj = (value: string) => value.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, "$1.$2.$3/$4-$5");

export default function PlatformPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando a plataforma...</p>}>
        <PlatformContent />
      </Suspense>
    </main>
  );
}

async function PlatformContent() {
  const user = await requireUser("/plataforma");
  if (!user.platformAdmin) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Plataforma</h1>
        <section className={styles.card}>
          <p>Esta área é só do administrador da plataforma.</p>
        </section>
      </>
    );
  }
  const [result, issuers] = await Promise.all([
    apiFetch<TenantRow[]>("/platform/tenants"),
    apiFetch<PendingIssuer[]>("/platform/import-issuers"),
  ]);
  if (!result.ok) redirectIfNeeded(result.error, "/plataforma");
  if (!issuers.ok) redirectIfNeeded(issuers.error, "/plataforma");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Plataforma</h1>
        <Link href="/plataforma/versoes">Versões do PDV</Link>
      </div>
      <section className={styles.card}>
        <h2>CNPJs aguardando destino</h2>
        <p className={styles.hint}>
          Notas importadas por um cliente com CNPJ que ele ainda não tem como filial. Criar cadastra a empresa e a filial
          (ou só a filial, quando a empresa de mesma raiz já existe) no cliente que importou, e as notas entram sozinhas.
          Recusar deixa as notas como ignoradas.
        </p>
        {!issuers.ok && <ErrorNotice error={issuers.error} />}
        {issuers.ok && issuers.data.length === 0 && <p className={styles.hint}>Nenhum CNPJ aguardando.</p>}
        {issuers.ok &&
          issuers.data.map((issuer) => (
            <article key={issuer.id} className={styles.card}>
              <h3>
                {formatCnpj(issuer.cnpj)} · {issuer.name ?? "Sem nome na nota"}
              </h3>
              <p className={styles.hint}>
                Cliente: <strong>{issuer.group_name}</strong> ·{" "}
                {issuer.kind === "company" ? "empresa nova" : `filial nova da empresa ${issuer.company_name ?? ""}`}
                {issuer.state && ` · ${issuer.state}`} · {issuer.notes} nota(s)
                {issuer.first_emitted_at &&
                  issuer.last_emitted_at &&
                  ` de ${dateText(issuer.first_emitted_at)} a ${dateText(issuer.last_emitted_at)}`}
              </p>
              <IssuerDecision issuer={issuer} />
            </article>
          ))}
      </section>
      <section className={styles.card}>
        <h2>Nova empresa</h2>
        <p className={styles.hint}>
          Cada empresa cadastrada aqui é um cliente separado: usuários, produtos, clientes, estoque, vendas, crediário e
          descontos só dela, sem aparecer para as outras. Você vê só o nome, o CNPJ e as quantidades. Outros CNPJs do
          mesmo dono são cadastrados depois pelo administrador da empresa, em Empresas.
        </p>
        <CreateTenantForm />
      </section>
      <section className={styles.card}>
        <h2>Clientes</h2>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && result.data.length === 0 && <p className={styles.hint}>Nenhum cliente cadastrado.</p>}
        {result.ok && result.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Cliente</th>
                  <th>Empresas (raiz do CNPJ)</th>
                  <th>Filiais</th>
                  <th>Usuários</th>
                  <th>Administrador</th>
                  <th>Desde</th>
                </tr>
              </thead>
              <tbody>
                {result.data.map((row) => (
                  <tr key={row.group_id}>
                    <td>{row.name}</td>
                    <td>
                      {row.companies.map((company) => (
                        <div key={company.cnpj_root}>
                          {company.trade_name || company.legal_name}
                          <small className={styles.hint}> · {rootText(company.cnpj_root)}</small>
                        </div>
                      ))}
                    </td>
                    <td>{row.branch_count}</td>
                    <td>{row.user_count}</td>
                    <td>{row.admin_email ?? "—"}</td>
                    <td>{dateText(row.created_at)}</td>
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
