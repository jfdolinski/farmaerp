import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Clientes · FarmaERP" };

const PAGE_LIMIT = 50;

interface CustomerRow {
  id: string;
  code: string;
  person_type: string;
  name: string;
  trade_name: string | null;
  document_masked: string;
  city: string | null;
  state: string | null;
}

type SearchParams = Promise<{ q?: string | string[] }>;

export default function CustomersPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando clientes...</p>}>
        <CustomersContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function CustomersContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/clientes");
  const canManage = can(user, "customers.manage");

  if (!can(user, "customers.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Clientes</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os clientes.</p>
        </section>
      </>
    );
  }

  const { q } = await searchParams;
  const query = typeof q === "string" ? q.trim() : "";
  const customers = await apiFetch<CustomerRow[]>(`/admin/customers?q=${encodeURIComponent(query)}`);
  if (!customers.ok) redirectIfNeeded(customers.error, "/clientes");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Clientes</h1>
        {canManage && <Link href="/clientes/novo">Novo cliente</Link>}
      </div>
      <section className={styles.card}>
        <form action="/clientes" className={styles.inline}>
          <label>
            Buscar
            <input
              name="q"
              type="search"
              size={40}
              maxLength={200}
              defaultValue={query}
              placeholder="Nome, código, CPF ou CNPJ completo"
            />
          </label>
          <button type="submit">Buscar</button>
        </form>
        {!customers.ok && <ErrorNotice error={customers.error} />}
        {customers.ok && customers.data.length === 0 && (
          <p className={styles.hint}>{query ? "Nenhum cliente encontrado." : "Nenhum cliente cadastrado ainda."}</p>
        )}
        {customers.ok && customers.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Código</th>
                  <th>Nome</th>
                  <th>Documento</th>
                  <th>Cidade</th>
                </tr>
              </thead>
              <tbody>
                {customers.data.map((customer) => (
                  <tr key={customer.id}>
                    <td>{customer.code}</td>
                    <td>
                      <Link href={`/clientes/${customer.id}`}>{customer.name}</Link>
                      {customer.trade_name && <small>{customer.trade_name}</small>}
                    </td>
                    <td>{customer.document_masked}</td>
                    <td>{[customer.city, customer.state].filter(Boolean).join(" - ")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {customers.ok && customers.data.length === PAGE_LIMIT && (
          <p className={styles.hint}>Mostrando os {PAGE_LIMIT} primeiros. Refine a busca para encontrar outros.</p>
        )}
      </section>
    </>
  );
}
