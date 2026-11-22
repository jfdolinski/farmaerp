import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { cnpjText } from "../../fornecedores/format";
import styles from "../../terminais/page.module.css";
import {
  dateTimeText,
  dayText,
  keyText,
  moneyText,
  quantityText,
  REASON_LABELS,
  SOURCE_LABELS,
  STATUS_LABELS,
} from "../format";
import { DiscardForm, ItemActions } from "../ui";

export const metadata: Metadata = { title: "Nota de compra · FarmaERP" };

interface InvoiceItem {
  id: string;
  item_number: number;
  supplier_code: string;
  barcode: string | null;
  description: string;
  ncm: string | null;
  cfop: string;
  unit: string;
  quantity: string;
  unit_price: string;
  products_value: string;
  discount_value: string;
  st_value: string;
  ipi_value: string;
  anvisa_code: string | null;
  pmc: string | null;
  product_id: string | null;
  product_code: string | null;
  product_name: string | null;
  match_source: string | null;
  fraction: string | null;
  stock_quantity: string | null;
  catalog_ms: string | null;
  ms_differs: boolean;
  sale_price: string | null;
  pmc_below_price: boolean;
  batches: { number: string; quantity: number; manufacturedOn: string | null; expiresOn: string }[];
}

interface InvoiceDetail {
  id: string;
  branch_name: string;
  supplier_id: string;
  supplier_name: string;
  emitter_cnpj: string;
  access_key: string;
  series: number;
  number: string;
  issued_at: string;
  authorized_at: string;
  protocol_number: string;
  environment: number;
  products_total: string;
  discount_total: string;
  freight_total: string;
  insurance_total: string;
  other_total: string;
  ipi_total: string;
  st_total: string;
  invoice_total: string;
  status: string;
  not_postable_reason: string | null;
  can_manage: boolean;
  items: InvoiceItem[];
}

type Params = Promise<{ id: string }>;

export default function InvoicePage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando nota...</p>}>
        <InvoiceContent params={params} />
      </Suspense>
    </main>
  );
}

async function InvoiceContent({ params }: { params: Params }) {
  const { id } = await params;
  const path = `/notas/${id}`;
  const user = await requireUser(path);

  if (!can(user, "purchases.view") && !can(user, "purchases.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota de compra</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as notas de compra.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<InvoiceDetail>(`/admin/purchase-invoices/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota de compra</h1>
        <ErrorNotice error={result.error} />
        <Link href="/notas">Voltar para notas</Link>
      </>
    );
  }
  const invoice = result.data;
  const reviewing = invoice.status === "review" && invoice.can_manage;
  const pending = invoice.items.filter((item) => !item.product_id).length;
  const totals: [string, string][] = [
    ["Produtos", invoice.products_total],
    ["Desconto", invoice.discount_total],
    ["Frete", invoice.freight_total],
    ["Seguro", invoice.insurance_total],
    ["Outras despesas", invoice.other_total],
    ["IPI", invoice.ipi_total],
    ["ICMS ST", invoice.st_total],
  ];

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>
          Nota {invoice.number} / {invoice.series}
        </h1>
        <Link href="/notas">Voltar para notas</Link>
      </div>

      <section className={styles.card}>
        <h2>{invoice.supplier_name}</h2>
        <p className={styles.hint}>
          <Link href={`/fornecedores/${invoice.supplier_id}`}>CNPJ {cnpjText(invoice.emitter_cnpj)}</Link> · Para{" "}
          {invoice.branch_name} · Emitida em {dateTimeText(invoice.issued_at)} · Protocolo {invoice.protocol_number}
        </p>
        <p className={styles.hint}>Chave {keyText(invoice.access_key)}</p>
        {invoice.environment === 2 && (
          <p className={styles.warning} role="status">
            Nota do ambiente de teste da Sefaz. Só a homologação aceita notas assim.
          </p>
        )}
        <p>
          <strong>{STATUS_LABELS[invoice.status] ?? invoice.status}</strong>
          {invoice.status === "review" &&
            (pending > 0 ? ` · ${pending} de ${invoice.items.length} itens a conferir` : " · Todos os itens ligados")}
        </p>
        {invoice.not_postable_reason && (
          <p className={styles.warning}>{REASON_LABELS[invoice.not_postable_reason] ?? invoice.not_postable_reason}</p>
        )}
        <div className={styles.tableWrap}>
          <table>
            <tbody>
              {totals
                .filter(([, value]) => Number(value) !== 0)
                .map(([label, value]) => (
                  <tr key={label}>
                    <th scope="row">{label}</th>
                    <td>{moneyText(value)}</td>
                  </tr>
                ))}
              <tr>
                <th scope="row">Total da nota</th>
                <td>
                  <strong>{moneyText(invoice.invoice_total)}</strong>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section className={styles.card}>
        <h2>Itens</h2>
        {invoice.items.map((item) => (
          <div key={item.id} className={styles.device}>
            <div className={styles.inline}>
              <strong>
                {item.item_number}. {item.description}
              </strong>
            </div>
            <p className={styles.hint}>
              {[
                `Código ${item.supplier_code}`,
                item.barcode && `EAN ${item.barcode}`,
                item.ncm && `NCM ${item.ncm}`,
                `CFOP ${item.cfop}`,
                `${quantityText(item.quantity)} ${item.unit} × ${moneyText(item.unit_price)} = ${moneyText(item.products_value)}`,
              ]
                .filter(Boolean)
                .join(" · ")}
            </p>
            {item.product_id ? (
              <p>
                <Link href={`/produtos/${item.product_id}`}>
                  {item.product_code} · {item.product_name}
                </Link>
                <small className={styles.hint}>
                  {" "}
                  {SOURCE_LABELS[item.match_source ?? ""] ?? ""} · Fracionamento {quantityText(item.fraction)} ·{" "}
                  Quantidade no estoque: {quantityText(item.stock_quantity)}
                </small>
              </p>
            ) : (
              <p className={styles.warning}>Sem produto ligado.</p>
            )}
            {item.batches.length > 0 && (
              <p className={styles.hint}>
                Lotes:{" "}
                {item.batches
                  .map((batch) => `${batch.number} (${quantityText(batch.quantity)}, validade ${dayText(batch.expiresOn)})`)
                  .join(", ")}
              </p>
            )}
            {item.ms_differs && (
              <p className={styles.warning}>
                O registro na Anvisa da nota ({item.anvisa_code}) é diferente do Catálogo ({item.catalog_ms}).
              </p>
            )}
            {item.pmc_below_price && (
              <p className={styles.warning}>
                O PMC da nota ({moneyText(item.pmc)}) é menor que o preço de venda ({moneyText(item.sale_price)}).
              </p>
            )}
            {reviewing && <ItemActions item={item} invoiceId={invoice.id} />}
          </div>
        ))}
      </section>

      {invoice.can_manage && (
        <section className={styles.card}>
          <DiscardForm invoiceId={invoice.id} />
        </section>
      )}
    </>
  );
}
