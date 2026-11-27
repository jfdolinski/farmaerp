import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CatalogResults, CatalogRow, controlledLabel } from "../catalog-results";
import { BarcodeLookupField, CatalogSearchButton } from "../catalog-search";
import { CatalogOrigin, CreateProductForm, ProductStructure } from "../ui";
import styles from "../../terminais/page.module.css";
import search from "../catalog-search.module.css";

export const metadata: Metadata = { title: "Novo produto · FarmaERP" };

type SearchParams = Promise<{
  q?: string | string[];
  ean?: string | string[];
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

const EMPTY_STRUCTURE: ProductStructure = {
  categories: [],
  groups: [],
  channels: [],
  units: [{ code: "UN", name: "Unidade", fractional: false }],
};

const param = (value: string | string[] | undefined) => (typeof value === "string" ? value.trim() : "");

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
  const query = param(params.q);
  const ean = /^\d{8,14}$/.test(param(params.ean)) ? param(params.ean) : "";
  const itemId = param(params.item);
  const withoutCatalog = params.semCatalogo === "1";
  // A busca automática pelo código de barras tem prioridade sobre a manual.
  const text = ean || query;

  const [catalog, structureResult] = await Promise.all([
    text ? apiFetch<CatalogRow[]>(`/admin/catalog?q=${encodeURIComponent(text)}`) : Promise.resolve(null),
    apiFetch<ProductStructure>("/admin/product-structure"),
  ]);
  if (structureResult && !structureResult.ok) {
    redirectIfNeeded(structureResult.error, "/produtos/novo");
  }
  const structure = structureResult.ok ? structureResult.data : EMPTY_STRUCTURE;
  const found = catalog?.ok ? catalog.data : [];
  // Pelo código, só vale o item que tem exatamente este código.
  const items = ean ? found.filter((item) => item.barcodes.includes(ean)) : found;
  const automatic = ean && items.length === 1 && !items[0].product_id ? items[0] : undefined;
  const chosen = items.find((item) => item.id === itemId && !item.product_id) ?? automatic;
  const origin: CatalogOrigin | null = chosen
    ? {
        source: ean ? "barcode" : "manual",
        kind: ean ? "lookup" : "search",
        query: text,
        resultCount: items.length,
      }
    : null;
  const showForm = withoutCatalog || Boolean(chosen);
  const base = "/produtos/novo";

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Novo produto</h1>
        <Link href="/produtos">Voltar para produtos</Link>
      </div>

      {!showForm && (
        <section className={styles.card}>
          <h2>Consulte o Catálogo</h2>
          <p className={styles.hint}>
            Leia ou digite o código de barras: a consulta é feita sozinha. Sem o código, busque pelo nome.
          </p>
          <BarcodeLookupField key={ean} base={base} initial={ean} />
          <CatalogSearchButton action={base} name="q" initial={query} label="Buscar no Catálogo pelo nome" />

          {catalog && !catalog.ok && <ErrorNotice error={catalog.error} />}
          {ean && catalog?.ok && items.length === 0 && (
            <div className={search.found} role="status">
              <strong>Nenhum item do Catálogo tem o código {ean}.</strong>
              <span className={styles.hint}>
                Busque pelo nome ou{" "}
                <Link href={`${base}?semCatalogo=1&ean=${ean}`}>cadastre sem Catálogo com este código</Link>.
              </span>
            </div>
          )}
          {ean && items.length === 1 && items[0].product_id && (
            <div className={search.found} role="status">
              <strong>Este código já está cadastrado.</strong>
              <Link href={`/produtos/${items[0].product_id}`}>Abrir o produto {items[0].name}</Link>
            </div>
          )}
          {!ean && query && catalog?.ok && items.length === 0 && (
            <p className={styles.hint}>Nenhum item encontrado no Catálogo para &quot;{query}&quot;.</p>
          )}
          {items.length > 0 && !(ean && items.length === 1) && (
            <CatalogResults
              items={items}
              actionLabel="Usar este item"
              hrefFor={(item) =>
                ean ? `${base}?ean=${ean}&item=${item.id}` : `${base}?q=${encodeURIComponent(query)}&item=${item.id}`
              }
            />
          )}
          <p className={styles.hint}>
            Não está no Catálogo? <Link href={`${base}?semCatalogo=1`}>Cadastrar sem Catálogo</Link>. O produto fica sem
            tributação e sem poder ser vendido até ser vinculado.
          </p>
        </section>
      )}

      {chosen && (
        <section className={styles.card}>
          <h2>Item do Catálogo</h2>
          {chosen === automatic && (
            <p className={styles.success} role="status">
              Encontrado automaticamente pelo código de barras {ean}.
            </p>
          )}
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
          <Link href={base}>Escolher outro item</Link>
        </section>
      )}

      {showForm && (
        <section className={styles.card}>
          <h2>{chosen ? "Complete o cadastro" : "Cadastro sem Catálogo"}</h2>
          {!chosen && <Link href={base}>Voltar para a consulta ao Catálogo</Link>}
          <CreateProductForm
            key={chosen?.id ?? "sem-catalogo"}
            values={{
              catalog_product_id: chosen?.id ?? null,
              display_name: chosen?.name ?? "",
            }}
            catalogBarcodes={chosen ? [...chosen.barcodes].sort((x, y) => (x === ean ? -1 : y === ean ? 1 : 0)) : []}
            structure={structure}
            origin={origin}
            barcode={chosen ? "" : ean}
          />
        </section>
      )}
    </>
  );
}
