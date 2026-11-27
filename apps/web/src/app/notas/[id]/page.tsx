import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { cnpjText } from "../../fornecedores/format";
import styles from "../../terminais/page.module.css";
import {
  costText,
  dateTimeText,
  dayText,
  keyText,
  moneyText,
  percentText,
  quantityText,
  REASON_LABELS,
  SOURCE_LABELS,
  STATUS_LABELS,
  CONFIRMATION_LABELS,
} from "../format";
import { ReturnsSection, type Returns } from "./returns";
import { BatchForm, CancelForm, DiscardForm, FractionForm, ItemActions, PostForm, ReleaseCostForm, ReverseForm } from "../ui";
import {
  AuditEntry,
  AuditSection,
  BatchesSection,
  ContentNotice,
  Installment,
  InstallmentsSection,
  ItemTaxes,
  itemContent,
  NoteDataSection,
} from "./xml-sections";

export const metadata: Metadata = { title: "Nota de compra · FarmaERP" };

interface Posting {
  fraction: string | null;
  stock_quantity: string | null;
  unit_cost: string | null;
  average_cost: string | null;
  new_average_cost: string | null;
  tolerance: string | null;
  difference_percent: string | null;
  cost_status: string;
  batch_status: string;
  batch_required: boolean | null;
  release: { reason: string; releasedBy: string; releasedAt: string; tolerance: number } | null;
}

interface InvoiceEvent {
  kind: "posted" | "reversed" | "cancelled";
  reason: string | null;
  created_at: string;
  user_name: string | null;
}

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
  posting: Posting | null;
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
  can_post: boolean;
  can_override_cost: boolean;
  can_cancel: boolean;
  can_negative_stock: boolean;
  cancel_reason: string | null;
  cancelled_by_name: string | null;
  returns: Returns;
  source: string;
  confirmation: string;
  confirmation_required: boolean;
  confirmed_at: string | null;
  confirmation_message: string | null;
  cancelled_at: string | null;
  items: InvoiceItem[];
  events: InvoiceEvent[];
  content: Record<string, unknown> | null;
  content_read_at: string | null;
  content_error: string | null;
  installments: Installment[];
  audit: AuditEntry[];
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
  const blockers = [
    ...(invoice.confirmation_required && invoice.confirmation !== "confirmed"
      ? [
          invoice.confirmation === "pending"
            ? "A nota ainda não foi confirmada pela Sefaz. Com o download automático ligado na filial, a confirmação chega sozinha em alguns minutos."
            : `A Sefaz não confirmou esta nota: ${invoice.confirmation_message ?? "o XML é diferente do autorizado"}`,
        ]
      : []),
    ...invoice.items.flatMap((item) => postingBlockers(item)),
  ];
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
        {invoice.events.length > 0 && (
          <ul className={`${styles.hint} ${styles.bullets}`}>
            {invoice.events.map((event) => (
              <li key={`${event.kind}-${event.created_at}`}>
                {EVENT_LABELS[event.kind]} por {event.user_name ?? "usuário"} em{" "}
                {dateTimeText(event.created_at)}
                {event.reason && `: ${event.reason}`}
              </li>
            ))}
          </ul>
        )}
        {invoice.cancelled_by_name && (
          <p className={styles.warning} role="status">
            Cancelada por {invoice.cancelled_by_name}: {invoice.cancel_reason}. A nota fica guardada e o mesmo XML não entra de novo.
          </p>
        )}
        {invoice.cancelled_at && (
          <p className={styles.warning} role="alert">
            {invoice.status === "posted"
              ? `O emitente cancelou esta nota em ${dateTimeText(invoice.cancelled_at)}, depois do lançamento. Confira com o fornecedor e, se for o caso, estorne o lançamento.`
              : `O emitente cancelou esta nota em ${dateTimeText(invoice.cancelled_at)}. Ela não pode mais ser lançada.`}
          </p>
        )}
        {invoice.status !== "cancelled" && (
          <p className={invoice.confirmation === "confirmed" ? styles.success : invoice.confirmation === "pending" ? styles.hint : styles.warning}>
            {invoice.confirmation_message
              ? invoice.confirmation_message.replace(/\.$/, "")
              : (CONFIRMATION_LABELS[invoice.confirmation] ?? invoice.confirmation)}
            {invoice.confirmed_at && ` em ${dateTimeText(invoice.confirmed_at)}`}
            {invoice.source === "download" && ". O XML veio do download da Sefaz"}
            {invoice.confirmation === "pending" && !invoice.confirmation_required && ". Fora da produção, a confirmação não é exigida para lançar"}
            .
          </p>
        )}
        {invoice.not_postable_reason && (
          <p className={styles.warning}>{REASON_LABELS[invoice.not_postable_reason] ?? invoice.not_postable_reason}</p>
        )}
        <ContentNotice content={invoice.content} error={invoice.content_error} />
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

      {invoice.content && <NoteDataSection content={invoice.content} />}

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
                {item.posting?.batch_status === "not_required" &&
                  ". O produto não controla lote nesta filial, então os lotes da nota não entram no estoque."}
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
            <ItemTaxes det={itemContent(invoice.content, item.item_number)} />
            {item.posting && invoice.status !== "cancelled" && <CostLine posting={item.posting} />}
            {item.posting && invoice.status !== "cancelled" && <BatchLine item={item} />}
            {reviewing && item.posting?.batch_required && (
              <BatchForm
                itemId={item.id}
                invoiceId={invoice.id}
                unit={item.unit}
                batches={item.batches}
                open={item.posting.batch_status === "missing"}
              />
            )}
            {invoice.status === "review" && invoice.can_override_cost && item.posting?.cost_status === "locked" && (
              <ReleaseCostForm itemId={item.id} invoiceId={invoice.id} />
            )}
            {invoice.status === "posted" && invoice.can_post && item.product_id && item.fraction && (
              <FractionForm
                itemId={item.id}
                invoiceId={invoice.id}
                unit={item.unit}
                quantity={item.quantity}
                fraction={item.fraction}
                canNegative={invoice.can_negative_stock}
              />
            )}
            {reviewing && <ItemActions item={item} invoiceId={invoice.id} />}
          </div>
        ))}
      </section>

      <InstallmentsSection installments={invoice.installments} read={invoice.content !== null} />

      <BatchesSection
        rows={invoice.items.flatMap((item) =>
          item.batches.map((batch) => ({
            itemNumber: item.item_number,
            description: item.description,
            unit: item.unit,
            ...batch,
          })),
        )}
      />

      <ReturnsSection
        invoiceId={invoice.id}
        data={invoice.returns}
        values={Object.fromEntries(
          invoice.items.map((item) => [
            item.id,
            { products: Number(item.products_value), entered: Number(item.posting?.stock_quantity ?? 0) },
          ]),
        )}
      />

      <AuditSection audit={invoice.audit} />

      {invoice.status === "review" && invoice.can_post && (
        <section className={styles.card}>
          <h2>Lançamento</h2>
          <PostForm invoiceId={invoice.id} blockers={blockers} />
        </section>
      )}

      {invoice.status === "posted" && invoice.can_post && (
        <section className={styles.card}>
          <ReverseForm invoiceId={invoice.id} canNegative={invoice.can_negative_stock} />
        </section>
      )}

      {invoice.can_cancel && invoice.status !== "cancelled" && (
        <section className={styles.card}>
          <CancelForm invoiceId={invoice.id} posted={invoice.status === "posted"} canNegative={invoice.can_negative_stock} />
        </section>
      )}

      {invoice.can_manage && invoice.status !== "posted" && !invoice.cancelled_by_name && (
        <section className={styles.card}>
          <DiscardForm invoiceId={invoice.id} />
        </section>
      )}
    </>
  );
}

const EVENT_LABELS: Record<InvoiceEvent["kind"], string> = {
  posted: "Lançada",
  reversed: "Estornada",
  cancelled: "Cancelada",
};

const BATCH_PROBLEMS: Record<string, string> = {
  missing: "Este produto exige lote nesta filial: informe os lotes do item.",
  mismatch: "A soma dos lotes é diferente da quantidade do item na nota.",
  expired: "Há lote vencido neste item. Produto vencido não entra no estoque.",
};

function postingBlockers(item: InvoiceItem): string[] {
  const label = `Item ${item.item_number}`;
  if (!item.posting || item.posting.cost_status === "no_product") return [`${label}: ligar a um produto.`];
  const found: string[] = [];
  if (item.posting.cost_status === "locked") found.push(`${label}: custo acima da tolerância, precisa ser liberado.`);
  if (item.posting.cost_status === "invalid") found.push(`${label}: quantidade da nota não dá estoque.`);
  const batch = BATCH_PROBLEMS[item.posting.batch_status];
  if (batch) found.push(`${label}: ${batch.charAt(0).toLowerCase()}${batch.slice(1)}`);
  return found;
}

/** Custo da entrada contra o médio da filial, e o que isso significa para o lançamento. */
function CostLine({ posting }: { posting: Posting }) {
  if (posting.cost_status === "no_product" || posting.unit_cost === null) return null;
  if (posting.cost_status === "posted") {
    return (
      <p className={styles.hint}>
        Entrou a {costText(posting.unit_cost)} por unidade.{" "}
        {posting.average_cost === null
          ? `O custo médio passou a ser ${costText(posting.new_average_cost)}.`
          : `Custo médio de ${costText(posting.average_cost)} para ${costText(posting.new_average_cost)}.`}
      </p>
    );
  }
  const base = `Custo por unidade: ${costText(posting.unit_cost)}`;
  if (posting.cost_status === "first_entry") {
    return <p className={styles.hint}>{base}. Primeira entrada nesta filial: este custo passa a ser o custo médio.</p>;
  }
  const comparison = `${base} · Custo médio: ${costText(posting.average_cost)}${
    posting.difference_percent === null ? "" : ` (${percentText(posting.difference_percent)})`
  }`;
  if (posting.cost_status === "locked") {
    return (
      <p className={styles.warning}>
        {comparison}. Passou da tolerância de {quantityText(posting.tolerance)}% e precisa ser liberado por quem pode
        liberar custo.
      </p>
    );
  }
  if (posting.cost_status === "released" && posting.release) {
    return (
      <p className={styles.success}>
        {comparison}. Liberado por {posting.release.releasedBy} em {dateTimeText(posting.release.releasedAt)}:{" "}
        {posting.release.reason}
      </p>
    );
  }
  if (posting.cost_status === "no_rule" && Number(posting.difference_percent) > 0) {
    return (
      <p className={styles.warning}>
        {comparison}. Não há tolerância de custo cadastrada para este produto, então o custo não trava: confira com a
        nota.
      </p>
    );
  }
  return <p className={styles.hint}>{comparison}.</p>;
}

function BatchLine({ item }: { item: InvoiceItem }) {
  const problem = item.posting ? BATCH_PROBLEMS[item.posting.batch_status] : undefined;
  if (!problem) return null;
  const total = item.batches.reduce((sum, batch) => sum + Number(batch.quantity), 0);
  return (
    <p className={styles.warning}>
      {problem}
      {item.posting?.batch_status === "mismatch" &&
        ` Lotes: ${quantityText(total)} ${item.unit}; item: ${quantityText(item.quantity)} ${item.unit}.`}
    </p>
  );
}
