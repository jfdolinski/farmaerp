import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { brl, dateTimeText } from "../../vendas/labels";
import { DESTINATION_LABELS, payoutText } from "../labels";
import { activeTab, TabItem, Tabs } from "../../shell/tabs";

export const metadata: Metadata = { title: "Devolução · FarmaERP" };

type Params = Promise<{ id: string }>;

interface ReturnDetail {
  id: string;
  code: string;
  branch_name: string;
  terminal_name: string;
  returned_at: string;
  sale_id: string;
  sale_code: string;
  sold_at: string;
  operator_name: string;
  authorized_by_name: string | null;
  customer_name: string | null;
  reason: string;
  destination: string;
  total: number;
  paid_at: string | null;
  paid_by_name: string | null;
  credit_used: number | null;
  credit_uses: { sale_id: string; sale_code: string; sold_at: string; amount: number }[];
  items: {
    line: number;
    product_id: string;
    product_code: number;
    product_name: string;
    quantity: number;
    amount: number;
  }[];
}

const quantityText = (value: number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

type SearchParams = Promise<{ aba?: string | string[] }>;

export default function ReturnPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando a devolução...</p>}>
        <ReturnContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ReturnContent({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const { id } = await params;
  const path = `/devolucoes/${id}`;
  const user = await requireUser(path);
  if (!can(user, "sales.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Devolução</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as devoluções.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ReturnDetail>(`/admin/returns/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, path);
    return (
      <>
        <AppHeader user={user} />
        <h1>Devolução</h1>
        <ErrorNotice error={result.error} />
        <Link href="/devolucoes">Voltar para as devoluções</Link>
      </>
    );
  }
  const refund = result.data;
  const tabs: TabItem[] = [
    { id: "resumo", label: "Resumo" },
    { id: "itens", label: "Itens devolvidos", count: refund.items.length },
    ...(refund.credit_uses.length > 0
      ? [{ id: "credito", label: "Uso do crédito", count: refund.credit_uses.length }]
      : []),
  ];
  const tab = activeTab(tabs, (await searchParams).aba);
  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Devolução {refund.code}</h1>
        <Link href="/devolucoes">Voltar para as devoluções</Link>
      </div>
      <Tabs base={path} items={tabs} active={tab}>
        <ReturnView refund={refund} tab={tab} />
      </Tabs>
    </>
  );
}

function ReturnView({ refund, tab }: { refund: ReturnDetail; tab: string }) {
  const paid = refund.paid_at !== null;
  return (
    <>
      {tab === "resumo" && (
        <section className={styles.card}>
          <p>
            {dateTimeText(refund.returned_at)} · {refund.branch_name} · {refund.terminal_name} · Feita por{" "}
            {refund.operator_name}
            {refund.authorized_by_name && `, liberada por ${refund.authorized_by_name}`}
          </p>
          <p>
            Venda <Link href={`/vendas/${refund.sale_id}`}>{refund.sale_code}</Link> de {dateTimeText(refund.sold_at)}
            {refund.customer_name && ` · Cliente: ${refund.customer_name}`}
          </p>
          <p>Motivo: {refund.reason}</p>
          <p>
            <strong>{DESTINATION_LABELS[refund.destination] ?? refund.destination}</strong> · {brl(refund.total)} ·{" "}
            {payoutText(refund.destination, paid, refund.total, refund.credit_used)}
            {paid && ` em ${dateTimeText(refund.paid_at!)} por ${refund.paid_by_name}`}
          </p>
        </section>
      )}
      {tab === "itens" && (
        <section className={styles.card}>
          <h2>Itens devolvidos</h2>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>Produto</th>
                  <th>Quantidade</th>
                  <th>Valor</th>
                </tr>
              </thead>
              <tbody>
                {refund.items.map((item) => (
                  <tr key={item.line}>
                    <td>{item.line}</td>
                    <td>
                      <Link href={`/produtos/${item.product_id}`}>
                        {item.product_code} · {item.product_name}
                      </Link>
                    </td>
                    <td>{quantityText(item.quantity)}</td>
                    <td>{brl(item.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className={styles.hint}>O estoque voltou para os lotes que saíram na venda.</p>
        </section>
      )}
      {tab === "credito" && (
        <section className={styles.card}>
          <h2>Uso do crédito</h2>
          <ul className={styles.bullets}>
            {refund.credit_uses.map((use) => (
              <li key={use.sale_id}>
                <Link href={`/vendas/${use.sale_id}`}>Venda {use.sale_code}</Link> · {dateTimeText(use.sold_at)} ·{" "}
                {brl(use.amount)}
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
