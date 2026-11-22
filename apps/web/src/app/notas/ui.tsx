"use client";

import Link from "next/link";
import { FormEvent, useActionState, useState, useTransition } from "react";
import type { ApiError } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import type { CatalogRow } from "../produtos/catalog-results";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import {
  discardInvoice,
  importXml,
  itemAction,
  ItemFormState,
  ProductOption,
  refreshInvoices,
  searchCatalog,
  searchProducts,
} from "./actions";

const MAX_FILES = 20;
const MAX_BYTES = 5 * 1024 * 1024;

interface FileResult {
  name: string;
  id?: string;
  error?: ApiError | { message: string; action: string; code: string; traceId: null; retryable: false };
}

/** Envia um arquivo por vez e mostra o resultado de cada um. */
export function UploadForm() {
  const [results, setResults] = useState<FileResult[]>([]);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const input = event.currentTarget.elements.namedItem("files") as HTMLInputElement;
    const files = Array.from(input.files ?? []);
    if (files.length === 0) return;
    setBusy(true);
    const done: FileResult[] = [];
    for (const file of files.slice(0, MAX_FILES)) {
      if (file.size > MAX_BYTES) {
        done.push({
          name: file.name,
          error: {
            code: "FA933",
            message: "O arquivo passa do tamanho máximo de 5 MB.",
            action: "Confira se é o XML da nota.",
            traceId: null,
            retryable: false,
          },
        });
      } else {
        done.push({ name: file.name, ...(await importXml(await file.text())) });
      }
      setResults([...done]);
    }
    for (const file of files.slice(MAX_FILES)) {
      done.push({
        name: file.name,
        error: {
          code: "FA005",
          message: `Envie até ${MAX_FILES} arquivos por vez.`,
          action: "Envie este arquivo numa próxima vez.",
          traceId: null,
          retryable: false,
        },
      });
    }
    setResults([...done]);
    setBusy(false);
    input.value = "";
    await refreshInvoices();
  }

  return (
    <form onSubmit={submit} className={styles.stack}>
      <div className={styles.inline}>
        <label>
          Arquivos XML da NF-e
          <input name="files" type="file" accept=".xml,text/xml,application/xml" multiple required />
        </label>
        <button type="submit" disabled={busy}>
          {busy ? "Importando..." : "Importar notas"}
        </button>
      </div>
      <p className={styles.hint}>
        Até {MAX_FILES} arquivos por vez, com até 5 MB cada. A filial é a do CNPJ do destinatário da nota.
      </p>
      {results.length > 0 && (
        <ul className={styles.stack} aria-live="polite">
          {results.map((result, index) => (
            <li key={`${result.name}-${index}`}>
              <strong>{result.name}</strong>{" "}
              {result.id ? (
                <span className={styles.success}>
                  Importada. <Link href={`/notas/${result.id}`}>Conferir</Link>
                </span>
              ) : (
                <ErrorNotice error={result.error as ApiError} />
              )}
            </li>
          ))}
        </ul>
      )}
    </form>
  );
}

export interface ItemRow {
  id: string;
  barcode: string | null;
  description: string;
  product_id: string | null;
}

function BarcodeFields({ item }: { item: ItemRow }) {
  if (item.barcode) {
    return <input type="hidden" name="barcode" value="" />;
  }
  return (
    <div className={styles.inline}>
      <label>
        Código de barras do produto novo
        <input name="barcode" maxLength={30} size={16} />
      </label>
      <label className={styles.check}>
        <input type="checkbox" name="barcodeIsInternal" />
        Código interno da loja
      </label>
    </div>
  );
}

/** Ligar a um produto, duplicar um parecido ou cadastrar pelo Catálogo. */
export function ItemActions({ item, invoiceId }: { item: ItemRow; invoiceId: string }) {
  const [mode, setMode] = useState<"product" | "catalog" | null>(null);
  const [query, setQuery] = useState(item.barcode ?? item.description);
  const [products, setProducts] = useState<ProductOption[]>();
  const [catalog, setCatalog] = useState<CatalogRow[]>();
  const [searchError, setSearchError] = useState<ApiError>();
  const [searching, startSearch] = useTransition();
  const [state, action, pending] = useActionState<ItemFormState, FormData>(itemAction, {});

  const search = (target: "product" | "catalog") =>
    startSearch(async () => {
      setSearchError(undefined);
      if (target === "product") {
        const result = await searchProducts(query);
        setProducts(result.rows);
        setSearchError(result.error);
      } else {
        const result = await searchCatalog(query);
        setCatalog(result.rows);
        setSearchError(result.error);
      }
    });

  return (
    <div className={styles.stack}>
      <div className={styles.inline}>
        <button type="button" onClick={() => setMode(mode === "product" ? null : "product")}>
          {item.product_id ? "Trocar produto" : "Ligar a um produto"}
        </button>
        {!item.product_id && (
          <button type="button" onClick={() => setMode(mode === "catalog" ? null : "catalog")}>
            Cadastrar pelo Catálogo
          </button>
        )}
      </div>
      {mode && (
        <div className={styles.device}>
          <div className={styles.inline}>
            <label>
              {mode === "product" ? "Buscar produto da loja" : "Buscar no Catálogo"}
              <input
                type="search"
                size={30}
                maxLength={200}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    search(mode);
                  }
                }}
              />
            </label>
            <button type="button" onClick={() => search(mode)} disabled={searching}>
              {searching ? "Buscando..." : "Buscar"}
            </button>
          </div>
          <ErrorNotice error={searchError} />
          {mode === "product" && products?.length === 0 && <p className={styles.hint}>Nenhum produto encontrado.</p>}
          {mode === "product" &&
            products?.map((product) => (
              <form key={product.id} action={action} onSubmit={keepValues(action)} className={styles.stack}>
                <input type="hidden" name="itemId" value={item.id} />
                <input type="hidden" name="invoiceId" value={invoiceId} />
                <input type="hidden" name="productId" value={product.id} />
                <div className={styles.inline}>
                  <span>
                    {product.code} · {product.display_name}
                  </span>
                  <button type="submit" name="intent" value="link" disabled={pending}>
                    Ligar
                  </button>
                  {!item.product_id && (
                    <details>
                      <summary>Duplicar como produto novo</summary>
                      <div className={styles.stack}>
                        <label>
                          Nome do produto novo
                          <input name="displayName" defaultValue={item.description} maxLength={150} size={30} />
                        </label>
                        <BarcodeFields item={item} />
                        <div>
                          <button type="submit" name="intent" value="duplicate" disabled={pending}>
                            Duplicar e ligar
                          </button>
                        </div>
                      </div>
                    </details>
                  )}
                </div>
              </form>
            ))}
          {mode === "catalog" && catalog?.length === 0 && <p className={styles.hint}>Nenhum item encontrado no Catálogo.</p>}
          {mode === "catalog" &&
            catalog?.map((row) => (
              <form key={row.id} action={action} onSubmit={keepValues(action)} className={styles.stack}>
                <input type="hidden" name="itemId" value={item.id} />
                <input type="hidden" name="invoiceId" value={invoiceId} />
                <input type="hidden" name="catalogProductId" value={row.id} />
                <div className={styles.inline}>
                  <span>
                    {row.name}
                    {row.manufacturer && <small> · {row.manufacturer}</small>}
                  </span>
                  {row.product_id ? (
                    <span className={styles.hint}>Já cadastrado na loja: use Ligar a um produto.</span>
                  ) : (
                    <details>
                      <summary>Cadastrar com este item</summary>
                      <div className={styles.stack}>
                        <label>
                          Nome de exibição
                          <input name="displayName" defaultValue={row.name} required maxLength={150} size={30} />
                        </label>
                        <BarcodeFields item={item} />
                        <div>
                          <button type="submit" name="intent" value="catalog" disabled={pending}>
                            Cadastrar e ligar
                          </button>
                        </div>
                      </div>
                    </details>
                  )}
                </div>
              </form>
            ))}
        </div>
      )}
      <ErrorNotice error={state.error} />
      {state.notice && (
        <p className={styles.success} role="status">
          {state.notice}
        </p>
      )}
    </div>
  );
}

export function DiscardForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState<ItemFormState, FormData>(discardInvoice, {});
  return (
    <details className={styles.reason}>
      <summary>Descartar esta nota</summary>
      <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <input type="hidden" name="id" value={invoiceId} />
        <label>
          Motivo
          <input name="reason" required maxLength={500} size={40} />
        </label>
        <p className={styles.hint}>
          A nota sai da lista e a chave fica livre para importar de novo. O XML continua guardado.
        </p>
        <div>
          <button type="submit" className={styles.danger} disabled={pending}>
            Descartar nota
          </button>
        </div>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}
