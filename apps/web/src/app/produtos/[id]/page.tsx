import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { CatalogResults, CatalogRow, controlledLabel } from "../catalog-results";
import { moneyText, regionLabel, statusLabel } from "../commercial-format";
import {
  AddPmcForm,
  BranchRow,
  PmcRow,
  PriceEvent,
  PriceForms,
  ReactivateForm,
  StatusEvent,
  StatusForm,
} from "../commercial-ui";
import {
  AddBarcodeForm,
  BarcodeCard,
  BarcodeRow,
  EditProductForm,
  ProductStructure,
  ProductValues,
} from "../ui";
import { BatchTrackingRow, TrackingRow } from "../../estoque/ui";
import { BalanceRow, dayText, quantityText } from "../../estoque/format";
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
  grid: BranchRow[];
  pmc: PmcRow[];
  prices: PriceEvent[];
  status_events: StatusEvent[];
}

const dateText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "America/Sao_Paulo",
  });

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
  const canPrice = can(user, "products.price");
  const canSeeStock = can(user, "stock.view");
  const canTrack = can(user, "stock.batch");

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

  const stock = canSeeStock
    ? await apiFetch<{ balances: BalanceRow[]; tracking: TrackingRow[] }>(
        `/admin/products/${encodeURIComponent(id)}/stock`,
      )
    : null;

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
        <h2>Preços e status por filial</h2>
        {product.grid.some((row) => row.above_pmc) && (
          <p className={styles.warning} role="status">
            Há filial com preço acima do PMC. Revise os preços abaixo.
          </p>
        )}
        {product.uses_pmc && product.grid.some((row) => !row.state) && (
          <p className={styles.warning} role="status">
            Há filial sem estado informado. Sem ele, o preço não pode ser salvo neste produto.{" "}
            <Link href="/produtos/estrutura">Informar em Estrutura</Link>.
          </p>
        )}
        {can(user, "products.status") ? (
          <StatusForm productId={product.id} grid={product.grid} />
        ) : (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Status</th>
                  <th>Preço em vigor</th>
                  <th>PMC</th>
                </tr>
              </thead>
              <tbody>
                {product.grid.map((row) => (
                  <tr key={row.branch_id}>
                    <td>{row.branch_name}</td>
                    <td>{statusLabel(row.status)}</td>
                    <td>
                      {moneyText(row.effective_price)}
                      {row.above_pmc && <small className={styles.warning}>Acima do PMC</small>}
                    </td>
                    <td>{moneyText(row.pmc)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {can(user, "products.reactivate") && product.grid.some((row) => row.status === "inactive") && (
          <ReactivateForm productId={product.id} grid={product.grid} />
        )}
        {canPrice && <PriceForms productId={product.id} grid={product.grid} />}
        <details className={styles.reason}>
          <summary>Histórico de preços</summary>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Onde</th>
                  <th>Preço</th>
                  <th>Motivo</th>
                  <th>Quem</th>
                </tr>
              </thead>
              <tbody>
                {product.prices.map((event, index) => (
                  <tr key={index}>
                    <td>{dateText(event.created_at)}</td>
                    <td>{event.branch_id ? event.branch_name : "Rede"}</td>
                    <td>{event.price === null ? "Exceção encerrada" : moneyText(event.price)}</td>
                    <td>{event.reason}</td>
                    <td>{event.author}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
        <details className={styles.reason}>
          <summary>Histórico de status</summary>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Filial</th>
                  <th>Mudança</th>
                  <th>Motivo</th>
                  <th>Quem</th>
                </tr>
              </thead>
              <tbody>
                {product.status_events.map((event, index) => (
                  <tr key={index}>
                    <td>{dateText(event.created_at)}</td>
                    <td>{event.branch_name}</td>
                    <td>
                      {statusLabel(event.old_status)} → {statusLabel(event.new_status)}
                    </td>
                    <td>{event.reason}</td>
                    <td>{event.author}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
      </section>

      {stock && !stock.ok && <ErrorNotice error={stock.error} />}
      {stock?.ok && (
        <section className={styles.card}>
          <div className={styles.header}>
            <h2>Estoque</h2>
            <Link href={`/estoque?q=${encodeURIComponent(product.code)}`}>Ver no estoque</Link>
          </div>
          {stock.data.balances.length === 0 && <p className={styles.hint}>Sem saldo neste produto.</p>}
          {stock.data.balances.length > 0 && (
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Filial</th>
                    <th>Lote</th>
                    <th>Validade</th>
                    <th>Saldo</th>
                  </tr>
                </thead>
                <tbody>
                  {stock.data.balances.map((row) => (
                    <tr key={row.balance_id}>
                      <td>{row.branch_name}</td>
                      <td>{row.batch_number ?? "Sem lote"}</td>
                      <td>
                        {dayText(row.expires_on)}
                        {row.is_expired && <small className={styles.warning}>Vencido</small>}
                      </td>
                      <td>{quantityText(row.quantity)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <h3>Controle de lote</h3>
          {stock.data.tracking.map((row) => (
            <BatchTrackingRow key={row.branch_id} productId={product.id} row={row} canManage={canTrack} />
          ))}
        </section>
      )}

      <section className={styles.card}>
        <h2>PMC</h2>
        {product.pmc.length === 0 && <p className={styles.hint}>Nenhum PMC informado.</p>}
        {product.pmc.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Estado</th>
                  <th>Região</th>
                  <th>Valor</th>
                  <th>Origem</th>
                  <th>Quando</th>
                </tr>
              </thead>
              <tbody>
                {product.pmc.map((row, index) => (
                  <tr key={index}>
                    <td>{row.state}</td>
                    <td>{regionLabel(row.pmc_region)}</td>
                    <td>{moneyText(row.value)}</td>
                    <td>{row.source === "catalog" ? "Catálogo" : row.source === "invoice" ? "Nota" : row.author ? `Digitado por ${row.author}` : "Digitado"}</td>
                    <td>{dateText(row.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {canPrice && <AddPmcForm productId={product.id} />}
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
