import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { CreateTenantForm } from "./ui";
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
  const result = await apiFetch<TenantRow[]>("/platform/tenants");
  if (!result.ok) redirectIfNeeded(result.error, "/plataforma");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Plataforma</h1>
        <Link href="/plataforma/versoes">Versões do PDV</Link>
      </div>
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
