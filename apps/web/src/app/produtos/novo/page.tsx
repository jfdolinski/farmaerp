import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CatalogResults, CatalogRow, controlledLabel } from "../catalog-results";
import { CreateProductForm, ProductStructure } from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Novo produto · FarmaERP" };

type SearchParams = Promise<{
  q?: string | string[];
  item?: string | string[];
  semCatalogo?: string | string[];
}>;

export default function NewProductPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando...</p>}>
        <NewProductContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

const EMPTY_STRUCTURE: ProductStructure = { categories: [], groups: [], channels: [] };

async function NewProductContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/produtos/novo");

  if (!can(user, "products.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Novo produto</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para cadastrar produtos.</p>
        </section>
      </>
    );
  }

  const params = await searchParams;
  const query = typeof params.q === "string" ? params.q.trim() : "";
  const itemId = typeof params.item === "string" ? params.item : "";
  const withoutCatalog = params.semCatalogo === "1";

  const [catalog, structureResult] = await Promise.all([
    query
      ? apiFetch<CatalogRow[]>(`/admin/catalog?q=${encodeURIComponent(query)}`)
      : Promise.resolve(null),
    apiFetch<ProductStructure>("/admin/product-structure"),
  ]);
  if (structureResult && !structureResult.ok) {
    redirectIfNeeded(structureResult.error, "/produtos/novo");
  }
  const structure = structureResult.ok ? structureResult.data : EMPTY_STRUCTURE;
  const items = catalog?.ok ? catalog.data : [];
  const chosen = items.find((item) => item.id === itemId);
  const showForm = withoutCatalog || Boolean(chosen);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Novo produto</h1>
        <Link href="/produtos">Voltar para produtos</Link>
      </div>

      {!showForm && (
        <section className={styles.card}>
          <h2>1. Consulte o Catálogo</h2>
          <form action="/produtos/novo" className={styles.inline}>
            <label>
              Nome, código de barras, princípio ativo ou fabricante
              <input name="q" type="search" size={50} maxLength={200} defaultValue={query} required />
            </label>
            <button type="submit">Consultar</button>
          </form>
          {catalog && !catalog.ok && <ErrorNotice error={catalog.error} />}
          {catalog?.ok && items.length > 0 && (
            <CatalogResults
              items={items}
              actionLabel="Usar este item"
              hrefFor={(item) =>
                `/produtos/novo?q=${encodeURIComponent(query)}&item=${item.id}`
              }
            />
          )}
          {catalog?.ok && items.length === 0 && (
            <p className={styles.hint}>Nenhum item encontrado no Catálogo.</p>
          )}
          <p className={styles.hint}>
            Não está no Catálogo?{" "}
            <Link href="/produtos/novo?semCatalogo=1">Cadastrar sem Catálogo</Link>. O produto fica
            sem tributação e sem poder ser vendido até ser vinculado.
          </p>
        </section>
      )}

      {chosen && (
        <section className={styles.card}>
          <h2>2. Confira os dados do Catálogo</h2>
          <p>
            <strong>{chosen.name}</strong>
          </p>
          <p className={styles.hint}>
            {[
              chosen.active_ingredient,
              chosen.manufacturer,
              chosen.ms_registration && `MS ${chosen.ms_registration}`,
              chosen.ncm && `NCM ${chosen.ncm}`,
              chosen.cest && `CEST ${chosen.cest}`,
              chosen.controlled_class && controlledLabel(chosen.controlled_class),
            ]
              .filter(Boolean)
              .join(" · ")}
          </p>
          <Link href={`/produtos/novo?q=${encodeURIComponent(query)}`}>Escolher outro item</Link>
        </section>
      )}

      {showForm && (
        <section className={styles.card}>
          <h2>{chosen ? "3. Complete o cadastro" : "Cadastro sem Catálogo"}</h2>
          {!chosen && <Link href="/produtos/novo">Voltar para a consulta ao Catálogo</Link>}
          <CreateProductForm
            key={chosen?.id ?? "sem-catalogo"}
            values={{
              catalog_product_id: chosen?.id ?? null,
              display_name: chosen?.name ?? "",
            }}
            catalogBarcodes={chosen?.barcodes ?? []}
            structure={structure}
          />
        </section>
      )}
    </>
  );
}
