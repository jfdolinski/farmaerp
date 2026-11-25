import { apiFetch } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import { brl, dateTimeText } from "../vendas/labels";
import styles from "../terminais/page.module.css";

interface Statement {
  available: number;
  waiting: number;
  next_expiry: string | null;
  consent: boolean;
  entries: {
    id: string;
    kind: "earn" | "refund" | "use" | "reverse" | "expire";
    amount: number;
    status: string | null;
    created_at: string;
    available_at: string | null;
    expires_at: string | null;
    sale_code: string | null;
    return_code: string | null;
    branch_name: string | null;
    remaining: number | null;
  }[];
}

const KIND_LABELS: Record<Statement["entries"][number]["kind"], string> = {
  earn: "Ganho",
  refund: "Volta de devolução",
  use: "Uso",
  reverse: "Estorno de devolução",
  expire: "Vencido",
};
const dayText = (value: string) =>
  new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" });

/** Cashback na ficha do cliente: saldo e extrato. */
export async function CashbackSection({ customerId }: { customerId: string }) {
  const result = await apiFetch<Statement>(`/admin/customers/${encodeURIComponent(customerId)}/cashback`);
  if (!result.ok) {
    return (
      <section className={styles.card}>
        <h2>Cashback</h2>
        <ErrorNotice error={result.error} />
      </section>
    );
  }
  const data = result.data;
  return (
    <section className={styles.card}>
      <h2>Cashback</h2>
      <p>
        Saldo disponível {brl(data.available)}
        {data.waiting > 0 && <> · {brl(data.waiting)} na carência</>}
        {data.next_expiry && <> · o próximo vence em {dayText(data.next_expiry)}</>}
      </p>
      {!data.consent && (
        <p className={styles.warning}>
          Sem o consentimento de cashback: o cliente não ganha nem usa. Registre em Consentimentos, se ele quiser.
        </p>
      )}
      {data.entries.length === 0 ? (
        <p className={styles.hint}>Nenhum lançamento.</p>
      ) : (
        <details className={styles.reason}>
          <summary>Extrato ({data.entries.length})</summary>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Lançamento</th>
                  <th>Valor</th>
                  <th>Origem</th>
                  <th>Validade</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((entry) => {
                  const negative = entry.kind === "use" || entry.kind === "reverse" || entry.kind === "expire";
                  return (
                    <tr key={entry.id}>
                      <td>{dateTimeText(entry.created_at)}</td>
                      <td>
                        {KIND_LABELS[entry.kind]}
                        {entry.kind === "use" && entry.status === "reserved" && <small className={styles.hint}> · reservado</small>}
                      </td>
                      <td>
                        {negative ? "-" : "+"}
                        {brl(entry.amount)}
                        {entry.remaining !== null && entry.remaining < entry.amount && entry.remaining > 0 && (
                          <small className={styles.hint}> · resta {brl(entry.remaining)}</small>
                        )}
                      </td>
                      <td>
                        {[entry.sale_code && `Venda ${entry.sale_code}`, entry.return_code && `Devolução ${entry.return_code}`, entry.branch_name]
                          .filter(Boolean)
                          .join(" · ")}
                      </td>
                      <td>
                        {entry.available_at && entry.expires_at
                          ? `${dayText(entry.available_at)} a ${dayText(entry.expires_at)}`
                          : "—"}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </details>
      )}
    </section>
  );
}
