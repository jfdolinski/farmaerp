import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { dateTimeText } from "../../vendas/labels";
import { type CountRow, dayText, quantityText, STATUS_LABELS } from "../labels";
import { ApplyForm, CancelForm, FileForm, ItemForm, RemoveItemButton } from "../ui";

export const metadata: Metadata = { title: "Inventário · FarmaERP" };

type Params = Promise<{ id: string }>;

interface CountDetail extends CountRow {
  items: {
    id: string;
    product_id: string;
    product_code: string;
    product_name: string;
    batch_number: string | null;
    expires_on: string | null;
    quantity: string;
    source: string;
  }[];
  review: {
    product_id: string;
    product_code: string;
    product_name: string;
    batch_number: string | null;
    expires_on: string | null;
    expected: string;
    counted: string;
    difference: string;
    was_counted: boolean;
    problem: string | null;
  }[];
}

/** Quantas linhas da conferência a tela mostra de uma vez. */
const SHOWN = 1000;

export default function CountPage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando inventário...</p>}>
        <CountContent params={params} />
      </Suspense>
    </main>
  );
}

async function CountContent({ params }: { params: Params }) {
  const { id } = await params;
  const user = await requireUser(`/inventario/${id}`);
  const result = await apiFetch<CountDetail>(`/admin/stock-counts/${encodeURIComponent(id)}`, { timeoutMs: 60_000 });
  if (!result.ok) {
    redirectIfNeeded(result.error, `/inventario/${id}`);
    return (
      <>
        <AppHeader user={user} />
        <h1>Inventário</h1>
        <p>
          <Link href="/inventario">Voltar aos inventários</Link>
        </p>
        <ErrorNotice error={result.error} />
      </>
    );
  }
  const count = result.data;
  const changes = count.review.filter((row) => Number(row.difference) !== 0 || row.problem);
  const problems = count.review.filter((row) => row.problem).length;
  const raised = count.review.filter((row) => row.was_counted && Number(row.difference) > 0).length;
  const lowered = count.review.filter((row) => row.was_counted && Number(row.difference) < 0).length;
  const zeroed = count.review.filter((row) => !row.was_counted && Number(row.difference) !== 0).length;
  const editable = count.can_change && can(user, "stock.opening");

  return (
    <>
      <AppHeader user={user} />
      <h1>Inventário de abertura · {count.branch_name}</h1>
      <p>
        <Link href="/inventario">Voltar aos inventários</Link>
      </p>
      <section className={styles.card}>
        <p>
          <strong>{STATUS_LABELS[count.status] ?? count.status}</strong> · corte em {dateTimeText(count.cutoff_at)}
          {count.note && ` · ${count.note}`}
        </p>
        <p className={styles.hint}>
          Aberto em {dateTimeText(count.created_at)}
          {count.created_by_name && ` por ${count.created_by_name}`}
          {count.applied_at && ` · aplicado em ${dateTimeText(count.applied_at)}`}
          {count.applied_by_name && ` por ${count.applied_by_name}`}.
        </p>
      </section>

      {editable && (
        <section className={styles.card}>
          <h2>Contar</h2>
          <p className={styles.hint}>
            Planilha em CSV com as colunas Código, Quantidade, Lote e Validade (o cabeçalho é opcional; sem ele, nessa
            ordem). Código pode ser o de barras, o interno ou o do sistema anterior. Lote e validade só para os produtos
            que exigem lote. Aceita ponto e vírgula ou vírgula e quantidade como 1.234,5.
          </p>
          <FileForm id={count.id} />
          <ItemForm id={count.id} />
        </section>
      )}

      <section className={styles.card}>
        <h2>Conferência</h2>
        <p>
          {count.items.length.toLocaleString("pt-BR")} linha(s) contada(s) · <strong>{raised}</strong> a acrescentar ·{" "}
          <strong>{lowered}</strong> a baixar · <strong>{zeroed}</strong> não contado(s) que vão a zero
          {problems > 0 && (
            <>
              {" "}
              · <strong className={styles.warning}>{problems} com problema</strong>
            </>
          )}
        </p>
        {changes.length === 0 ? (
          <p className={styles.hint}>Nenhuma diferença: o contado é igual ao saldo no corte.</p>
        ) : (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Produto</th>
                  <th>Lote</th>
                  <th>Saldo no corte</th>
                  <th>Contado</th>
                  <th>Diferença</th>
                </tr>
              </thead>
              <tbody>
                {changes.slice(0, SHOWN).map((row) => (
                  <tr key={`${row.product_id}-${row.batch_number ?? ""}`}>
                    <td>
                      {row.product_name}
                      <small className={styles.hint}> · {row.product_code}</small>
                      {row.problem && <small className={styles.warning}> {row.problem}</small>}
                    </td>
                    <td>
                      {row.batch_number ?? "—"}
                      {row.expires_on && <small className={styles.hint}> · val. {dayText(row.expires_on)}</small>}
                    </td>
                    <td>{quantityText(row.expected)}</td>
                    <td>{row.was_counted ? quantityText(row.counted) : <small className={styles.hint}>não contado</small>}</td>
                    <td>
                      {Number(row.difference) > 0 ? "+" : ""}
                      {quantityText(row.difference)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {changes.length > SHOWN && (
          <p className={styles.hint}>Mostrando as primeiras {SHOWN} diferenças de {changes.length.toLocaleString("pt-BR")}.</p>
        )}
        {editable && <ApplyForm id={count.id} zeroed={zeroed} blocked={problems > 0} />}
      </section>

      {count.items.length > 0 && (
        <section className={styles.card}>
          <h2>Linhas contadas</h2>
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Produto</th>
                  <th>Lote</th>
                  <th>Quantidade</th>
                  <th>Origem</th>
                  {editable && <th />}
                </tr>
              </thead>
              <tbody>
                {count.items.slice(0, SHOWN).map((item) => (
                  <tr key={item.id}>
                    <td>
                      {item.product_name}
                      <small className={styles.hint}> · {item.product_code}</small>
                    </td>
                    <td>
                      {item.batch_number ?? "—"}
                      {item.expires_on && <small className={styles.hint}> · val. {dayText(item.expires_on)}</small>}
                    </td>
                    <td>{quantityText(item.quantity)}</td>
                    <td>{item.source === "file" ? "Planilha" : "Digitado"}</td>
                    {editable && (
                      <td>
                        <RemoveItemButton id={count.id} itemId={item.id} />
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {count.items.length > SHOWN && <p className={styles.hint}>Mostrando as primeiras {SHOWN} linhas.</p>}
        </section>
      )}

      {editable && (
        <section className={styles.card}>
          <h2>Desistir</h2>
          <CancelForm id={count.id} />
        </section>
      )}
    </>
  );
}
