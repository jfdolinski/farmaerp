import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { cnpjText } from "./format";

export const metadata: Metadata = { title: "Fornecedores · FarmaERP" };

const PAGE_LIMIT = 50;

interface SupplierListRow {
  id: string;
  cnpj: string;
  legal_name: string;
  trade_name: string | null;
  city: string | null;
  state: string | null;
  product_count: string;
}

type SearchParams = Promise<{ q?: string | string[] }>;

export default function SuppliersPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando fornecedores...</p>}>
        <SuppliersContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SuppliersContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/fornecedores");
  const canManage = can(user, "purchases.manage");

  if (!can(user, "purchases.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Fornecedores</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os fornecedores.</p>
        </section>
      </>
    );
  }

  const { q } = await searchParams;
  const query = typeof q === "string" ? q.trim() : "";
  const suppliers = await apiFetch<SupplierListRow[]>(`/admin/suppliers?q=${encodeURIComponent(query)}`);
  if (!suppliers.ok) redirectIfNeeded(suppliers.error, "/fornecedores");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Fornecedores</h1>
        {canManage && <Link href="/fornecedores/novo">Novo fornecedor</Link>}
      </div>
      <section className={styles.card}>
        <form action="/fornecedores" className={styles.inline}>
          <label>
            Buscar
            <input
              name="q"
              type="search"
              size={40}
              maxLength={200}
              defaultValue={query}
              placeholder="Nome ou CNPJ, com ao menos 8 dígitos"
            />
          </label>
          <button type="submit">Buscar</button>
        </form>
        {!suppliers.ok && <ErrorNotice error={suppliers.error} />}
        {suppliers.ok && suppliers.data.length === 0 && (
          <p className={styles.hint}>{query ? "Nenhum fornecedor encontrado." : "Nenhum fornecedor cadastrado ainda."}</p>
        )}
        {suppliers.ok && suppliers.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Fornecedor</th>
                  <th>CNPJ</th>
                  <th>Cidade</th>
                  <th>Códigos</th>
                </tr>
              </thead>
              <tbody>
                {suppliers.data.map((supplier) => (
                  <tr key={supplier.id}>
                    <td>
                      <Link href={`/fornecedores/${supplier.id}`}>{supplier.legal_name}</Link>
                      {supplier.trade_name && <small>{supplier.trade_name}</small>}
                    </td>
                    <td>{cnpjText(supplier.cnpj)}</td>
                    <td>{[supplier.city, supplier.state].filter(Boolean).join(" - ")}</td>
                    <td>{Number(supplier.product_count).toLocaleString("pt-BR")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {suppliers.ok && suppliers.data.length === PAGE_LIMIT && (
          <p className={styles.hint}>Mostrando os {PAGE_LIMIT} primeiros. Refine a busca para encontrar outros.</p>
        )}
      </section>
    </>
  );
}
