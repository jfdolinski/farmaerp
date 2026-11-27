import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { DESTINATION_LABELS, payoutText } from "../../devolucoes/labels";
import { alertText, brl, dateTimeText, FISCAL_LABELS, PAYMENT_LABELS } from "../labels";
import { activeTab, TabItem, Tabs } from "../../shell/tabs";

export const metadata: Metadata = { title: "Venda · FarmaERP" };

type Params = Promise<{ id: string }>;

interface SaleDetail {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  sold_at: string;
  received_at: string;
  operator_name: string;
  seller_name: string | null;
  quote_id: string | null;
  quote_code: string | null;
  returns: {
    id: string;
    code: string;
    returned_at: string;
    total: number;
    destination: string;
    reason: string;
    paid: boolean;
  }[];
  customer_name: string | null;
  customer_code: number | null;
  fiscal_model: string | null;
  fiscal_status: string;
  nfce: {
    id: string;
    model: string;
    series: number;
    number: number;
    access_key: string;
    environment: number;
    emission_type: number;
    status: string;
    protocol: string | null;
    status_code: string | null;
    reason: string | null;
    emitted_at: string;
    authorized_at: string | null;
  } | null;
  subtotal: number;
  discount_total: number;
  total: number;
  coupon: string | null;
  items: {
    id: string;
    line: number;
    product_id: string;
    product_code: number;
    product_name: string;
    quantity: number;
    unit_price: number;
    central_price: number | null;
    discount: number;
    auto_discount: number;
    discount_rules: { rule_id: string; name: string; amount: number }[];
    total: number;
    batches: { number: string; quantity: number }[];
    /** Orçamentos juntados no caixa: cada item com o vendedor e o orçamento de origem. */
    seller_name?: string | null;
    quote_code?: string | null;
  }[];
  payments: {
    method: string;
    amount: number;
    change: number;
    card_brand: string | null;
    authorization_code: string | null;
    agreement_name: string | null;
    agreement_registration: string | null;
    return_id: string | null;
    return_code: string | null;
  }[];
  alerts: { kind: string; line: number | null; detail: Record<string, unknown> }[];
}

const quantityText = (value: number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

type SearchParams = Promise<{ aba?: string | string[] }>;

export default function SalePage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando a venda...</p>}>
        <SaleContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function SaleContent({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const { id } = await params;
  const path = `/vendas/${id}`;
  const user = await requireUser(path);
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Venda</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<SaleDetail>(`/admin/sales/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Venda</h1>
        <ErrorNotice error={result.error} />
        <Link href="/vendas">Voltar para as vendas</Link>
      </>
    );
  }
  const sale = result.data;
  const tabs: TabItem[] = [
    { id: "resumo", label: "Resumo", attention: sale.alerts.length > 0 },
    { id: "itens", label: "Itens", count: sale.items.length },
    { id: "pagamento", label: "Pagamento" },
    ...(sale.returns.length > 0 ? [{ id: "devolucoes", label: "Devoluções", count: sale.returns.length }] : []),
  ];
  const tab = activeTab(tabs, (await searchParams).aba);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Venda {sale.code}</h1>
        <Link href="/vendas">Voltar para as vendas</Link>
      </div>
      <Tabs base={path} items={tabs} active={tab}>
        <SaleView sale={sale} tab={tab} />
      </Tabs>
    </>
  );
}

function SaleView({ sale, tab }: { sale: SaleDetail; tab: string }) {
  const late = new Date(sale.received_at).getTime() - new Date(sale.sold_at).getTime() > 10 * 60 * 1000;
  return (
    <>
      {tab === "resumo" && (
        <>
          <section className={styles.card}>
            <p>
              {dateTimeText(sale.sold_at)} · {sale.branch_name} · {sale.terminal_name} · Operador: {sale.operator_name}
              {sale.seller_name && ` · Vendedor: ${sale.seller_name}`}
            </p>
            {sale.coupon && <p>Cupom: {sale.coupon}</p>}
            <p>
              Cliente:{" "}
              {sale.customer_name ? `${sale.customer_name} (código ${sale.customer_code})` : "Não identificado"}
            </p>
            <p>
              {FISCAL_LABELS[sale.fiscal_status] ?? sale.fiscal_status}
              {sale.fiscal_model && ` · modelo ${sale.fiscal_model === "65" ? "NFC-e" : "NF-e"}`}
            </p>
            {sale.nfce && (
              <>
                <p>
                  {sale.nfce.model === "55" ? "NF-e" : "NFC-e"} série {sale.nfce.series} nº {sale.nfce.number}
                  {sale.nfce.environment === 2 && " (homologação, sem valor fiscal)"} · chave{" "}
                  <code>{sale.nfce.access_key.replace(/(\d{4})(?=\d)/g, "$1 ")}</code>
                </p>
                {sale.nfce.protocol && sale.nfce.authorized_at && (
                  <p>
                    Protocolo {sale.nfce.protocol} em {dateTimeText(sale.nfce.authorized_at)}
                  </p>
                )}
                {sale.nfce.status !== "authorized" && sale.nfce.reason && (
                  <p className={styles.warning}>
                    Sefaz{sale.nfce.status_code ? ` (${sale.nfce.status_code})` : ""}: {sale.nfce.reason}
                  </p>
                )}
                <p>
                  <a href={`/vendas/${sale.id}/nfce`}>Baixar o XML</a>
                  {sale.nfce.model === "55" && sale.nfce.status === "authorized" && (
                    <>
                      {" "}
                      · <a href={`/notas-fiscais/${sale.nfce.id}/danfe`}>DANFE (A4)</a>
                    </>
                  )}
                </p>
              </>
            )}
            {sale.quote_id && (
              <p>
                Veio do orçamento <Link href={`/orcamentos/${sale.quote_id}`}>{sale.quote_code}</Link>
              </p>
            )}
            {late && (
              <p className={styles.hint}>
                Chegou à central em {dateTimeText(sale.received_at)} (o terminal estava sem internet).
              </p>
            )}
          </section>

          {sale.alerts.length > 0 && (
            <section className={styles.card}>
              <h2>Alertas</h2>
              <ul className={styles.bullets}>
                {sale.alerts.map((alert, index) => (
                  <li key={index}>
                    {alert.line !== null && <strong>Item {alert.line}: </strong>}
                    {alertText(alert.kind, alert.detail)}
                  </li>
                ))}
              </ul>
            </section>
          )}
        </>
      )}

      {tab === "itens" && (
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
                {sale.items.map((item) => (
                  <tr key={item.id}>
                    <td>{item.line}</td>
                    <td>
                      <Link href={`/produtos/${item.product_id}`}>
                        {item.product_code} · {item.product_name}
                      </Link>
                      {item.batches.length > 0 && (
                        <small className={styles.hint}>
                          Lotes:{" "}
                          {item.batches.map((batch) => `${batch.number} (${quantityText(batch.quantity)})`).join(", ")}
                        </small>
                      )}
                      {item.seller_name && (item.seller_name !== sale.seller_name || item.quote_code) && (
                        <small className={styles.hint}>
                          {" "}
                          Vendedor: {item.seller_name}
                          {item.quote_code && ` · orçamento ${item.quote_code}`}
                        </small>
                      )}
                    </td>
                    <td>{quantityText(item.quantity)}</td>
                    <td>{brl(item.unit_price)}</td>
                    <td>
                      {item.discount > 0 ? brl(item.discount) : "—"}
                      {(item.discount_rules ?? []).map((rule) => (
                        <small key={rule.rule_id}>
                          {rule.name}: {brl(rule.amount)}
                        </small>
                      ))}
                      {item.discount - (item.auto_discount ?? 0) > 0.004 && (item.auto_discount ?? 0) > 0 && (
                        <small>Manual: {brl(item.discount - item.auto_discount)}</small>
                      )}
                    </td>
                    <td>{brl(item.total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p>
            Subtotal {brl(sale.subtotal)} · Descontos {brl(sale.discount_total)} ·{" "}
            <strong>Total {brl(sale.total)}</strong>
          </p>
        </section>
      )}

      {tab === "pagamento" && (
        <section className={styles.card}>
          <h2>Pagamento</h2>
          <ul className={styles.bullets}>
            {sale.payments.map((payment, index) => (
              <li key={index}>
                {PAYMENT_LABELS[payment.method] ?? payment.method}: {brl(payment.amount)}
                {payment.change > 0 && ` (troco ${brl(payment.change)})`}
                {payment.card_brand && ` · ${payment.card_brand}`}
                {payment.authorization_code && ` · autorização ${payment.authorization_code}`}
                {payment.agreement_name && ` · ${payment.agreement_name}`}
                {payment.agreement_registration && ` · matrícula ${payment.agreement_registration}`}
                {payment.return_id && (
                  <>
                    {" · "}
                    <Link href={`/devolucoes/${payment.return_id}`}>{payment.return_code}</Link>
                  </>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {tab === "devolucoes" && (
        <section className={styles.card}>
          <h2>Devoluções</h2>
          <ul className={styles.bullets}>
            {sale.returns.map((refund) => (
              <li key={refund.id}>
                <Link href={`/devolucoes/${refund.id}`}>{refund.code}</Link> · {dateTimeText(refund.returned_at)} ·{" "}
                {brl(refund.total)} · {DESTINATION_LABELS[refund.destination] ?? refund.destination} (
                {payoutText(refund.destination, refund.paid).toLowerCase()}) · {refund.reason}
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
