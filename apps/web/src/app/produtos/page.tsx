import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Produtos · FarmaERP" };

const PAGE_LIMIT = 50;

interface ProductRow {
  id: string;
  code: string;
  display_name: string;
  catalog_product_id: string | null;
  active_ingredient: string | null;
  manufacturer: string | null;
  primary_barcode: string | null;
  online_sale_blocked: boolean;
}

type SearchParams = Promise<{ q?: string | string[] }>;

export default function ProductsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando produtos...</p>}>
        <ProductsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ProductsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/produtos");
  const canManage = can(user, "products.manage");

  if (!can(user, "products.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Produtos</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os produtos.</p>
        </section>
      </>
    );
  }

  const { q } = await searchParams;
  const query = typeof q === "string" ? q.trim() : "";
  const products = await apiFetch<ProductRow[]>(
    `/admin/products?q=${encodeURIComponent(query)}`,
  );
  if (!products.ok) redirectIfNeeded(products.error, "/produtos");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Produtos</h1>
        <div className={styles.nav}>
          {canManage && <Link href="/produtos/novo">Novo produto</Link>}
          <Link href="/produtos/estrutura">Estrutura</Link>
        </div>
      </div>
      <section className={styles.card}>
        <form action="/produtos" className={styles.inline}>
          <label>
            Buscar
            <input
              name="q"
              type="search"
              size={50}
              maxLength={200}
              defaultValue={query}
              placeholder="Nome, código, código de barras, princípio ativo ou fabricante"
            />
          </label>
          <button type="submit">Buscar</button>
        </form>
        {!products.ok && <ErrorNotice error={products.error} />}
        {products.ok && products.data.length === 0 && (
          <p className={styles.hint}>
            {query ? "Nenhum produto encontrado." : "Nenhum produto cadastrado ainda."}
          </p>
        )}
        {products.ok && products.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Código</th>
                  <th>Produto</th>
                  <th>Fabricante</th>
                  <th>Código de barras</th>
                </tr>
              </thead>
              <tbody>
                {products.data.map((product) => (
                  <tr key={product.id}>
                    <td>{product.code}</td>
                    <td>
                      <Link href={`/produtos/${product.id}`}>{product.display_name}</Link>
                      {product.active_ingredient && <small>{product.active_ingredient}</small>}
                      {!product.catalog_product_id && (
                        <small className={styles.warning}>Sem Catálogo</small>
                      )}
                    </td>
                    <td>{product.manufacturer ?? "Não informado"}</td>
                    <td>{product.primary_barcode}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {products.ok && products.data.length === PAGE_LIMIT && (
          <p className={styles.hint}>
            Mostrando os {PAGE_LIMIT} primeiros. Refine a busca para encontrar outros.
          </p>
        )}
      </section>
    </>
  );
}
