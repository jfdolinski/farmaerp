import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { brl, dateTimeText } from "../../vendas/labels";
import { QUOTE_STATUS_LABELS } from "../labels";

export const metadata: Metadata = { title: "Orçamento · FarmaERP" };

type Params = Promise<{ id: string }>;

interface QuoteDetail {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  seller_name: string;
  customer_name: string | null;
  customer_code: number | null;
  card_number: number | null;
  status: string;
  quoted_at: string;
  expires_at: string;
  subtotal: number;
  discount_total: number;
  total: number;
  replaced_by_code: string | null;
  sale_id: string | null;
  sale_code: string | null;
  items: {
    line: number;
    product_id: string;
    product_code: number;
    product_name: string;
    quantity: number;
    unit_price: number;
    discount: number;
    total: number;
    released_by_name: string | null;
    release_reason: string | null;
  }[];
}

const quantityText = (value: number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

export default function QuotePage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando o orçamento...</p>}>
        <QuoteContent params={params} />
      </Suspense>
    </main>
  );
}

async function QuoteContent({ params }: { params: Params }) {
  const { id } = await params;
  const user = await requireUser(`/orcamentos/${id}`);
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Orçamento</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os orçamentos.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<QuoteDetail>(`/admin/quotes/${encodeURIComponent(id)}`);
  if (!result.ok) redirectIfNeeded(result.error, `/orcamentos/${id}`);
  return (
    <>
      <AppHeader user={user} />
      <p>
        <Link href="/orcamentos">Voltar para os orçamentos</Link>
      </p>
      {!result.ok && <ErrorNotice error={result.error} />}
      {result.ok && <QuoteView quote={result.data} />}
    </>
  );
}

function QuoteView({ quote }: { quote: QuoteDetail }) {
  return (
    <>
      <h1>Orçamento {quote.code}</h1>
      <section className={styles.card}>
        <p>
          {dateTimeText(quote.quoted_at)} · {quote.branch_name} · {quote.terminal_name} · Vendedor: {quote.seller_name}
        </p>
        <p>
          Cliente: {quote.customer_name ? `${quote.customer_name} (código ${quote.customer_code})` : "Não identificado"}
          {quote.card_number !== null && ` · Plaquinha ${quote.card_number}`}
        </p>
        <p>
          <strong>{QUOTE_STATUS_LABELS[quote.status] ?? quote.status}</strong> · vale até {dateTimeText(quote.expires_at)}
          {quote.replaced_by_code && ` · a plaquinha passou para o orçamento ${quote.replaced_by_code}`}
          {quote.sale_id && (
            <>
              {" · "}
              <Link href={`/vendas/${quote.sale_id}`}>Venda {quote.sale_code}</Link>
            </>
          )}
        </p>
      </section>
      <section className={styles.card}>
        <h2>Itens</h2>
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Produto</th>
                <th>Quantidade</th>
                <th>Preço</th>
                <th>Desconto</th>
                <th>Total</th>
              </tr>
            </thead>
            <tbody>
              {quote.items.map((item) => (
                <tr key={item.line}>
                  <td>{item.line}</td>
                  <td>
                    <Link href={`/produtos/${item.product_id}`}>
                      {item.product_code} · {item.product_name}
                    </Link>
                  </td>
                  <td>{quantityText(item.quantity)}</td>
                  <td>{brl(item.unit_price)}</td>
                  <td>
                    {item.discount > 0 ? brl(item.discount) : "—"}
                    {item.released_by_name && (
                      <small className={styles.hint}>
                        Liberado por {item.released_by_name}: {item.release_reason}
                      </small>
                    )}
                  </td>
                  <td>{brl(item.total)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>
          Subtotal {brl(quote.subtotal)} · Descontos {brl(quote.discount_total)} · <strong>Total {brl(quote.total)}</strong>
        </p>
        <p className={styles.hint}>No caixa, o preço é recalculado com as condições da hora da venda.</p>
      </section>
    </>
  );
}
