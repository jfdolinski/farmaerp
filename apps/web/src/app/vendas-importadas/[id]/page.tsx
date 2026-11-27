import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { brl, dateTimeText } from "../../vendas/labels";
import { CARD_BRAND_LABELS, NOTE_PAYMENT_LABELS, noteText } from "../labels";
import { activeTab, TabItem, Tabs } from "../../shell/tabs";

export const metadata: Metadata = { title: "Venda importada · FarmaERP" };

type Params = Promise<{ id: string }>;

interface ImportedSaleDetail {
  id: string;
  branch_name: string;
  access_key: string;
  model: string;
  series: number;
  number: number;
  emitted_at: string;
  protocol: string | null;
  customer_id: string | null;
  customer_name: string | null;
  customer_code: number | null;
  subtotal: number;
  discount_total: number;
  total: number;
  change: number;
  canceled_at: string | null;
  imported_at: string;
  import_id: string;
  file_name: string;
  items: {
    line: number;
    product_id: string;
    product_code: number;
    legacy_code: string | null;
    product_name: string;
    quantity: number;
    unit_price: number;
    discount: number;
    total: number;
    cfop: string | null;
  }[];
  payments: {
    method: string;
    description: string | null;
    amount: number;
    card_brand: string | null;
    authorization_code: string | null;
  }[];
}

const quantityText = (value: number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

type SearchParams = Promise<{ aba?: string | string[] }>;

export default function ImportedSalePage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando venda...</p>}>
        <ImportedSaleContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ImportedSaleContent({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const { id } = await params;
  const path = `/vendas-importadas/${id}`;
  const user = await requireUser(path);
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Venda importada</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as vendas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ImportedSaleDetail>(`/admin/imported-sales/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Venda importada</h1>
        <p>
          <Link href="/vendas-importadas">Voltar às vendas importadas</Link>
        </p>
        <ErrorNotice error={result.error} />
      </>
    );
  }
  const sale = result.data;
  const tabs: TabItem[] = [
    { id: "resumo", label: "Resumo" },
    { id: "itens", label: "Itens", count: sale.items.length },
    { id: "pagamento", label: "Pagamento" },
  ];
  const tab = activeTab(tabs, (await searchParams).aba);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Venda importada · {noteText(sale.model, sale.series, sale.number)}</h1>
        <Link href="/vendas-importadas">Voltar às vendas importadas</Link>
      </div>
      <Tabs base={path} items={tabs} active={tab}>
        {tab === "resumo" && (
          <section className={styles.card}>
            {sale.canceled_at && (
              <p className={styles.warning}>
                Nota cancelada na Sefaz em {dateTimeText(sale.canceled_at)}. A venda foi desfeita e o estoque devolvido.
              </p>
            )}
            <p>
              <strong>Emissão:</strong> {dateTimeText(sale.emitted_at)} · <strong>Filial:</strong> {sale.branch_name}
            </p>
            <p>
              <strong>Cliente:</strong>{" "}
              {sale.customer_id ? (
                <Link href={`/clientes/${sale.customer_id}`}>
                  {sale.customer_name} (código {sale.customer_code})
                </Link>
              ) : (
                "Não identificado"
              )}
            </p>
            <p>
              <strong>Chave:</strong> <small>{sale.access_key}</small>
              {sale.protocol && (
                <>
                  {" "}
                  · <strong>Protocolo:</strong> {sale.protocol}
                </>
              )}
            </p>
            <p className={styles.hint}>
              Importada em {dateTimeText(sale.imported_at)} do arquivo{" "}
              {can(user, "imports.manage") ? (
                <Link href={`/importacoes/${sale.import_id}`}>{sale.file_name}</Link>
              ) : (
                sale.file_name
              )}
              . <a href={`/vendas-importadas/${sale.id}/xml`}>Baixar o XML</a>
            </p>
          </section>
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
                    <th>Código anterior</th>
                    <th>Quantidade</th>
                    <th>Preço</th>
                    <th>Desconto</th>
                    <th>Total</th>
                    <th>CFOP</th>
                  </tr>
                </thead>
                <tbody>
                  {sale.items.map((item) => (
                    <tr key={item.line}>
                      <td>{item.line}</td>
                      <td>
                        <Link href={`/produtos/${item.product_id}`}>{item.product_name}</Link>
                        <small className={styles.hint}> · {item.product_code}</small>
                      </td>
                      <td>{item.legacy_code ?? "—"}</td>
                      <td>{quantityText(item.quantity)}</td>
                      <td>{brl(item.unit_price)}</td>
                      <td>{Number(item.discount) > 0 ? brl(item.discount) : "—"}</td>
                      <td>{brl(item.total)}</td>
                      <td>{item.cfop ?? "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p>
              Subtotal {brl(sale.subtotal)}
              {Number(sale.discount_total) > 0 && ` · desconto ${brl(sale.discount_total)}`} ·{" "}
              <strong>total {brl(sale.total)}</strong>
            </p>
          </section>
        )}

        {tab === "pagamento" && (
          <section className={styles.card}>
            <h2>Pagamento</h2>
            {sale.payments.length === 0 ? (
              <p className={styles.hint}>A nota não trouxe o pagamento.</p>
            ) : (
              <ul className={styles.bullets}>
                {sale.payments.map((payment, index) => (
                  <li key={index}>
                    {payment.description ?? NOTE_PAYMENT_LABELS[payment.method] ?? `Forma ${payment.method}`}:{" "}
                    {brl(payment.amount)}
                    {payment.card_brand &&
                      ` · ${CARD_BRAND_LABELS[payment.card_brand] ?? `bandeira ${payment.card_brand}`}`}
                    {payment.authorization_code && ` · autorização ${payment.authorization_code}`}
                  </li>
                ))}
              </ul>
            )}
            {Number(sale.change) > 0 && <p>Troco: {brl(sale.change)}</p>}
          </section>
        )}
      </Tabs>
    </>
  );
}
