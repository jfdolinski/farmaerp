import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../../shell/tabs";
import { ProductSupplierForm, SupplierForm, SupplierRow } from "../ui";

export const metadata: Metadata = { title: "Fornecedor · FarmaERP" };

interface SupplierDetail extends SupplierRow {
  products: {
    id: string;
    supplier_code: string;
    fraction_quantity: string | null;
    effective_fraction: string;
    product_id: string;
    product_code: string;
    product_name: string;
  }[];
}

type Params = Promise<{ id: string }>;
type SearchParams = Promise<{ aba?: string | string[] }>;

export default function SupplierPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando fornecedor...</p>}>
        <SupplierContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SupplierContent({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const { id } = await params;
  const path = `/fornecedores/${id}`;
  const user = await requireUser(path);
  const canManage = can(user, "purchases.manage");

  if (!can(user, "purchases.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Fornecedor</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os fornecedores.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<SupplierDetail>(`/admin/suppliers/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Fornecedor</h1>
        <ErrorNotice error={result.error} />
        <Link href="/fornecedores">Voltar para fornecedores</Link>
      </>
    );
  }
  const supplier = result.data;
  const tabs: TabItem[] = [
    { id: "cadastro", label: "Cadastro" },
    { id: "produtos", label: "Códigos nos produtos", count: supplier.products.length },
  ];
  const tab = activeTab(tabs, (await searchParams).aba);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>{supplier.trade_name || supplier.legal_name}</h1>
        <Link href="/fornecedores">Voltar para fornecedores</Link>
      </div>
      <Tabs base={path} items={tabs} active={tab}>
        {tab === "cadastro" && (
          <section className={styles.card}>
            <h2>Cadastro</h2>
            <SupplierForm supplier={supplier} canManage={canManage} />
          </section>
        )}
        {tab === "produtos" && (
          <section className={styles.card}>
            <h2>Códigos nos produtos</h2>
            {supplier.products.length === 0 && (
              <p className={styles.hint}>
                Nenhum código ligado ainda. Ligue pelo cadastro do produto, na aba Fornecedores. Na entrada de nota, os
                códigos novos serão ligados durante a conferência.
              </p>
            )}
            {supplier.products.map((row) => (
              <ProductSupplierForm
                key={row.id}
                row={row}
                canManage={canManage}
                next={path}
                title={
                  <Link href={`/produtos/${row.product_id}`}>
                    {row.product_code} · {row.product_name}
                  </Link>
                }
              />
            ))}
            {supplier.products.length === 500 && <p className={styles.hint}>Mostrando os 500 primeiros códigos.</p>}
          </section>
        )}
      </Tabs>
    </>
  );
}
