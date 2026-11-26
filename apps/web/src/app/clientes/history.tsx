import Link from "next/link";
import { apiFetch } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";

export interface CustomerHistory {
  sales_12m: number;
  total_12m: number | string;
  average_ticket: number | string | null;
  last_purchase_at: string | null;
  last_30_days: { sale_id: string; code: string; sold_at: string; branch_name: string; total: number | string; items: number; imported?: boolean }[];
  recurring: { product_id: string; name: string; purchases: number; quantity: number | string; last_at: string }[];
}

const quantityText = (value: number | string) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

/** Compras do cliente: ticket médio (12 meses), últimos 30 dias e produtos recorrentes (180 dias). */
export async function CustomerHistorySection({ customerId, canSeeSales }: { customerId: string; canSeeSales: boolean }) {
  const result = await apiFetch<CustomerHistory>(`/admin/customers/${encodeURIComponent(customerId)}/history`);
  if (!result.ok) return <ErrorNotice error={result.error} />;
  const history = result.data;
  return (
    <>
      <p className={styles.hint}>Nas filiais que você vê, incluindo as vendas importadas do sistema anterior. Ticket médio dos últimos 12 meses; recorrentes: em 2 ou mais compras nos últimos 180 dias.</p>
      <p>
        <strong>Ticket médio:</strong> {history.average_ticket === null ? "—" : brl(history.average_ticket)} ·{" "}
        {history.sales_12m === 1 ? "1 compra" : `${history.sales_12m.toLocaleString("pt-BR")} compras`} em 12 meses (
        {brl(history.total_12m)})
        {history.last_purchase_at && ` · última em ${dateTimeText(history.last_purchase_at)}`}
      </p>
      <h3>Últimos 30 dias</h3>
      {history.last_30_days.length === 0 ? (
        <p className={styles.hint}>Nenhuma compra nos últimos 30 dias.</p>
      ) : (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Data</th>
                <th>Venda</th>
                <th>Loja</th>
                <th>Itens</th>
                <th>Total</th>
              </tr>
            </thead>
            <tbody>
              {history.last_30_days.map((sale) => (
                <tr key={sale.sale_id}>
                  <td>{dateTimeText(sale.sold_at)}</td>
                  <td>
                    {canSeeSales ? (
                      <Link href={sale.imported ? `/vendas-importadas/${sale.sale_id}` : `/vendas/${sale.sale_id}`}>
                        {sale.code}
                      </Link>
                    ) : (
                      sale.code
                    )}
                    {sale.imported && <small className={styles.hint}> · importada</small>}
                  </td>
                  <td>{sale.branch_name}</td>
                  <td>{sale.items}</td>
                  <td>{brl(sale.total)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <h3>Produtos recorrentes</h3>
      {history.recurring.length === 0 ? (
        <p className={styles.hint}>Nenhum produto comprado mais de uma vez nos últimos 180 dias.</p>
      ) : (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Produto</th>
                <th>Compras</th>
                <th>Quantidade</th>
                <th>Última</th>
              </tr>
            </thead>
            <tbody>
              {history.recurring.map((item) => (
                <tr key={item.product_id}>
                  <td>{item.name}</td>
                  <td>{item.purchases}</td>
                  <td>{quantityText(item.quantity)}</td>
                  <td>{dateTimeText(item.last_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
