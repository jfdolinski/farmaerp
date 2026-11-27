"use client";

import { useActionState, useState } from "react";
import { ErrorNotice } from "../../error-notice";
import { keepValues } from "../../produtos/ui";
import styles from "../../terminais/page.module.css";
import { emitReturnNfe, ItemFormState, returnToSupplier } from "../actions";
import { dateTimeText, dayText, moneyText, quantityText } from "../format";

export interface ReturnBatch {
  batch_id: string | null;
  batch_number: string | null;
  expires_on: string | null;
  entered: number;
  returned: number;
  available: number;
}

export interface ReturnItem {
  item_id: string;
  item_number: number;
  description: string;
  unit: string;
  fractional: boolean;
  invoice_unit: string;
  entered: number;
  returned: number;
  available: number;
  batches: ReturnBatch[];
}

export interface DoneReturn {
  id: string;
  number: number;
  reason: string;
  created_at: string;
  user_name: string;
  products_value: number;
  discount_value: number;
  freight_value: number;
  insurance_value: number;
  other_value: number;
  ipi_value: number;
  st_value: number;
  fcp_st_value: number;
  total_value: number;
  items: {
    item_number: number;
    description: string;
    quantity: number;
    unit: string;
    invoice_quantity: number;
    invoice_unit: string;
    batch_number: string | null;
    unit_price: number;
    total_value: number;
  }[];
}

export interface Returns {
  can_return: boolean;
  items: ReturnItem[];
  returns: DoneReturn[];
}

/** NF-e de devolução emitida pela central (a mais recente de cada devolução é a que vale). */
export interface ReturnNfe {
  id: string;
  return_id: string;
  series: number;
  number: number;
  access_key: string;
  status: "pending" | "authorized" | "rejected";
  protocol: string | null;
  status_code: string | null;
  reason: string | null;
  total_value: number;
  emitted_at: string;
  authorized_at: string | null;
}

/** Situação da NF-e da devolução, os arquivos e o botão de emitir ou transmitir de novo. */
function ReturnNfeCell({
  invoiceId,
  returnId,
  nfe,
  canIssue,
}: {
  invoiceId: string;
  returnId: string;
  nfe?: ReturnNfe;
  canIssue: boolean;
}) {
  const [state, action, pending] = useActionState<ItemFormState, FormData>(emitReturnNfe, {});
  const label = !nfe ? "Emitir NF-e" : nfe.status === "pending" ? "Transmitir de novo" : "Emitir de novo";
  return (
    <div className={styles.stack}>
      {!nfe && <span className={styles.hint}>Sem NF-e</span>}
      {nfe?.status === "authorized" && (
        <>
          <span className={styles.success}>
            Autorizada · nº {nfe.number} série {nfe.series}
            {nfe.authorized_at && <small className={styles.hint}> em {dateTimeText(nfe.authorized_at)}</small>}
          </span>
          <span>
            <a href={`/nfe-central/${nfe.id}/danfe`}>DANFE</a> · <a href={`/nfe-central/${nfe.id}/xml`}>XML</a>
          </span>
        </>
      )}
      {nfe?.status === "pending" && (
        <span className={styles.warning}>
          Pendente: a Sefaz ainda não respondeu (nº {nfe.number} série {nfe.series}).
        </span>
      )}
      {nfe?.status === "rejected" && (
        <span className={styles.warning}>
          Recusada pela Sefaz{nfe.status_code && ` (${nfe.status_code})`}: {nfe.reason ?? "sem motivo informado"}
        </span>
      )}
      {canIssue && nfe?.status !== "authorized" && (
        <form action={action}>
          <input type="hidden" name="returnId" value={returnId} />
          <input type="hidden" name="invoiceId" value={invoiceId} />
          <button type="submit" disabled={pending}>
            {pending ? "Transmitindo..." : label}
          </button>
        </form>
      )}
      <ErrorNotice error={state.error} />
      {state.notice && (
        <small className={state.error ? styles.warning : styles.hint} role="status">
          {state.notice}
        </small>
      )}
    </div>
  );
}

/** Valor dos produtos do item na nota, para a prévia (o banco faz a conta certa). */
export type ItemValues = Record<string, { products: number; entered: number }>;

const parse = (value: string) => {
  const n = Number(value.replace(",", "."));
  return value.trim() === "" || !Number.isFinite(n) ? 0 : n;
};

/** Devolução ao fornecedor: saldo por item e lote, formulário e as devoluções feitas. */
export function ReturnsSection({
  invoiceId,
  data,
  values,
  nfes = [],
  canIssueNfe = false,
}: {
  invoiceId: string;
  data: Returns;
  values: ItemValues;
  nfes?: ReturnNfe[];
  canIssueNfe?: boolean;
}) {
  // A lista vem da mais antiga para a mais nova: fica a última de cada devolução.
  const nfeOf = new Map(nfes.map((nfe) => [nfe.return_id, nfe]));
  const [state, action, pending] = useActionState<ItemFormState, FormData>(returnToSupplier, {});
  const [typed, setTyped] = useState<Record<string, string>>({});
  const open = data.items.filter((item) => item.available > 0);
  const preview = Object.entries(typed).reduce((sum, [key, text]) => {
    const itemId = key.split(":")[0];
    const item = values[itemId];
    return item && item.entered > 0 ? sum + (parse(text) / item.entered) * item.products : sum;
  }, 0);

  if (!data.can_return && data.returns.length === 0) return null;
  return (
    <section className={styles.card}>
      <h2>Devoluções ao fornecedor</h2>
      {data.returns.length > 0 && (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Devolução</th>
                <th>Itens</th>
                <th>Motivo</th>
                <th>Total</th>
                <th>NF-e de devolução</th>
              </tr>
            </thead>
            <tbody>
              {data.returns.map((done) => (
                <tr key={done.id}>
                  <td>
                    {done.number}ª · {dateTimeText(done.created_at)}
                    <br />
                    <small className={styles.hint}>{done.user_name}</small>
                  </td>
                  <td>
                    {done.items.map((line) => (
                      <div key={`${line.item_number}-${line.batch_number ?? ""}`}>
                        {line.item_number}. {line.description}: {quantityText(line.quantity)} {line.unit}
                        <small className={styles.hint}>
                          {" "}
                          ({quantityText(line.invoice_quantity)} {line.invoice_unit}
                          {line.batch_number && `, lote ${line.batch_number}`}) · {moneyText(line.total_value)}
                        </small>
                      </div>
                    ))}
                  </td>
                  <td>{done.reason}</td>
                  <td>
                    <strong>{moneyText(done.total_value)}</strong>
                  </td>
                  <td>
                    <ReturnNfeCell
                      invoiceId={invoiceId}
                      returnId={done.id}
                      nfe={nfeOf.get(done.id)}
                      canIssue={canIssueNfe}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {data.can_return && open.length === 0 && (
        <p className={styles.hint}>Tudo o que esta nota pôs no estoque já foi devolvido.</p>
      )}

      {data.can_return && open.length > 0 && (
        <details className={styles.reason}>
          <summary>Devolver itens ao fornecedor</summary>
          <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
            <input type="hidden" name="id" value={invoiceId} />
            <p className={styles.hint}>
              Informe a quantidade na unidade do produto. Cada item volta com o mesmo preço da nota e com desconto,
              frete, impostos e despesas na proporção. Sai do lote escolhido, pelo custo da entrada, e o custo médio é
              refeito. Depois da primeira devolução, a nota não pode mais ser estornada, cancelada nem ter o
              fracionamento alterado.
            </p>
            <div className={styles.tableWrap}>
              <table>
                <thead>
                  <tr>
                    <th>Item</th>
                    <th>Lote</th>
                    <th>Entrou</th>
                    <th>Devolvido</th>
                    <th>Pode devolver</th>
                    <th>Devolver agora</th>
                  </tr>
                </thead>
                <tbody>
                  {open.flatMap((item) =>
                    item.batches
                      .filter((batch) => batch.available > 0)
                      .map((batch) => {
                        const key = `${item.item_id}:${batch.batch_id ?? ""}`;
                        return (
                          <tr key={key}>
                            <td>
                              {item.item_number}. {item.description}
                            </td>
                            <td>
                              {batch.batch_number
                                ? `${batch.batch_number}${batch.expires_on ? ` (validade ${dayText(batch.expires_on)})` : ""}`
                                : "Sem lote"}
                            </td>
                            <td>
                              {quantityText(batch.entered)} {item.unit}
                            </td>
                            <td>
                              {quantityText(batch.returned)} {item.unit}
                            </td>
                            <td>
                              {quantityText(batch.available)} {item.unit}
                            </td>
                            <td style={{ whiteSpace: "nowrap" }}>
                              <input
                                name={`q:${key}`}
                                inputMode="decimal"
                                size={8}
                                aria-label={`Devolver do item ${item.item_number}${batch.batch_number ? `, lote ${batch.batch_number}` : ""}`}
                                placeholder={item.fractional ? "0,000" : "0"}
                                value={typed[key] ?? ""}
                                onChange={(event) => setTyped({ ...typed, [key]: event.target.value })}
                              />{" "}
                              {item.unit}
                            </td>
                          </tr>
                        );
                      }),
                  )}
                </tbody>
              </table>
            </div>
            {preview > 0 && (
              <p className={styles.hint} role="status">
                Produtos a devolver: cerca de {moneyText(preview)} (o total com impostos e despesas sai na devolução).
              </p>
            )}
            <label>
              Motivo
              <input name="reason" required maxLength={500} size={40} />
            </label>
            <div>
              <button type="submit" className={styles.danger} disabled={pending}>
                Devolver ao fornecedor
              </button>
            </div>
            <ErrorNotice error={state.error} />
            {state.notice && (
              <p className={styles.success} role="status">
                {state.notice}
              </p>
            )}
          </form>
        </details>
      )}
    </section>
  );
}
