import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CatalogResults, CatalogRow, controlledLabel } from "../catalog-results";
import {
  AddBarcodeForm,
  BarcodeCard,
  BarcodeRow,
  EditProductForm,
  ProductStructure,
  ProductValues,
} from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Produto · FarmaERP" };

interface ProductDetail extends ProductValues {
  id: string;
  code: string;
  display_name: string;
  catalog_name: string | null;
  active_ingredient: string | null;
  catalog_manufacturer: string | null;
  ms_registration: string | null;
  controlled_class: string | null;
  ncm: string | null;
  cest: string | null;
  barcodes: BarcodeRow[];
}

type Params = Promise<{ id: string }>;
type SearchParams = Promise<{ catalogo?: string | string[]; vincular?: string | string[] }>;

export default function ProductPage({
  params,
  searchParams,
}: {
  params: Params;
  searchParams: SearchParams;
}) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando produto...</p>}>
        <ProductContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

const EMPTY_STRUCTURE: ProductStructure = { categories: [], groups: [], channels: [] };

async function ProductContent({
  params,
  searchParams,
}: {
  params: Params;
  searchParams: SearchParams;
}) {
  const { id } = await params;
  const path = `/produtos/${id}`;
  const user = await requireUser(path);
  const canManage = can(user, "products.manage");

  if (!can(user, "products.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Produto</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os produtos.</p>
        </section>
      </>
    );
  }

  const [productResult, structureResult] = await Promise.all([
    apiFetch<ProductDetail>(`/admin/products/${encodeURIComponent(id)}`),
    apiFetch<ProductStructure>("/admin/product-structure"),
  ]);
  if (!productResult.ok) {
    redirectIfNeeded(productResult.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Produto</h1>
        <ErrorNotice error={productResult.error} />
        <Link href="/produtos">Voltar para produtos</Link>
      </>
    );
  }
  const product = productResult.data;
  const structure = structureResult.ok ? structureResult.data : EMPTY_STRUCTURE;

  const { catalogo, vincular } = await searchParams;
  const query = typeof catalogo === "string" ? catalogo.trim() : "";
  const linkingId = typeof vincular === "string" ? vincular : "";
  const catalog =
    !product.catalog_product_id && canManage && query
      ? await apiFetch<CatalogRow[]>(`/admin/catalog?q=${encodeURIComponent(query)}`)
      : null;
  const items = catalog?.ok ? catalog.data : [];
  const linking = items.find((item) => item.id === linkingId && !item.product_id);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>
          {product.code} · {product.display_name}
        </h1>
        <Link href="/produtos">Voltar para produtos</Link>
      </div>

      <section className={styles.card}>
        <h2>Dados do Catálogo</h2>
        {product.catalog_product_id ? (
          <>
            <p>
              <strong>{product.catalog_name}</strong>
            </p>
            <p className={styles.hint}>
              {[
                product.active_ingredient,
                product.catalog_manufacturer,
                product.ms_registration && `MS ${product.ms_registration}`,
                product.ncm && `NCM ${product.ncm}`,
                product.cest && `CEST ${product.cest}`,
                product.controlled_class && controlledLabel(product.controlled_class),
              ]
                .filter(Boolean)
                .join(" · ")}
            </p>
            <p className={styles.hint}>Estes dados vêm do Catálogo e não são editados pela loja.</p>
          </>
        ) : (
          <>
            <p className={styles.warning}>
              Sem Catálogo: fica sem tributação e sem poder ser vendido até ser vinculado.
            </p>
            {canManage && (
              <form action={path} className={styles.inline}>
                <label>
                  Consultar o Catálogo para vincular
                  <input name="catalogo" type="search" size={40} maxLength={200} defaultValue={query} required />
                </label>
                <button type="submit">Consultar</button>
              </form>
            )}
            {catalog && !catalog.ok && <ErrorNotice error={catalog.error} />}
            {catalog?.ok && items.length === 0 && (
              <p className={styles.hint}>Nenhum item encontrado no Catálogo.</p>
            )}
            {items.length > 0 && (
              <CatalogResults
                items={items}
                actionLabel="Vincular"
                hrefFor={(item) =>
                  `${path}?catalogo=${encodeURIComponent(query)}&vincular=${item.id}`
                }
              />
            )}
            {linking && (
              <p role="status">
                Será vinculado a <strong>{linking.name}</strong>. Confira e confirme abaixo.
              </p>
            )}
          </>
        )}
      </section>

      <section className={styles.card}>
        <h2>Cadastro</h2>
        <EditProductForm
          key={linking?.id ?? "cadastro"}
          values={product}
          structure={structure}
          canManage={canManage}
          linkingTo={linking?.id}
        />
      </section>

      <section className={styles.card}>
        <h2>Códigos de barras</h2>
        {product.barcodes.map((barcode) => (
          <BarcodeCard
            key={barcode.id}
            productId={product.id}
            barcode={barcode}
            channels={structure.channels}
            canManage={canManage}
          />
        ))}
        {canManage && <AddBarcodeForm productId={product.id} channels={structure.channels} />}
      </section>
    </>
  );
}
