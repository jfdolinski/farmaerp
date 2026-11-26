import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { brl, dateTimeText } from "../../vendas/labels";
import { documentText, ENTRY_KINDS, KIND_LABELS } from "../labels";

export const metadata: Metadata = { title: "Nota importada · FarmaERP" };

type Params = Promise<{ id: string }>;

interface ImportedNoteDetail {
  id: string;
  branch_name: string;
  counterpart_branch_name: string | null;
  kind: string;
  access_key: string;
  series: number;
  number: number;
  emitted_at: string;
  protocol: string | null;
  cfop: string | null;
  supplier_id: string | null;
  supplier_name: string | null;
  party_document: string | null;
  party_name: string | null;
  total: number;
  canceled_at: string | null;
  imported_at: string;
  import_id: string;
  file_name: string;
  items: {
    line: number;
    product_id: string;
    product_code: number;
    product_name: string;
    supplier_code: string | null;
    note_quantity: number;
    quantity: number;
    unit: string | null;
    total: number;
    unit_cost: number | null;
    cfop: string | null;
    batches: { number: string | null; quantity: number | null; manufactured_on: string | null; expires_on: string | null }[];
  }[];
}

const quantityText = (value: number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });
const dayText = (value: string | null) => (value ? value.split("-").reverse().join("/") : "—");

export default function ImportedNotePage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando nota...</p>}>
        <ImportedNoteContent params={params} />
      </Suspense>
    </main>
  );
}

async function ImportedNoteContent({ params }: { params: Params }) {
  const { id } = await params;
  const user = await requireUser(`/notas-importadas/${id}`);
  if (!can(user, "stock.view") && !can(user, "purchases.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota importada</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver o estoque nem as compras.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ImportedNoteDetail>(`/admin/imported-notes/${encodeURIComponent(id)}`);
  if (!result.ok) {
    redirectIfNeeded(result.error, `/notas-importadas/${id}`);
    return (
      <>
        <AppHeader user={user} />
        <h1>Nota importada</h1>
        <p>
          <Link href="/notas-importadas">Voltar às notas importadas</Link>
        </p>
        <ErrorNotice error={result.error} />
      </>
    );
  }
  const note = result.data;
  const entry = ENTRY_KINDS.has(note.kind);

  return (
    <>
      <AppHeader user={user} />
      <h1>
        {KIND_LABELS[note.kind] ?? note.kind} · NF-e {note.series}/{note.number}
      </h1>
      <p>
        <Link href="/notas-importadas">Voltar às notas importadas</Link>
      </p>
      <section className={styles.card}>
        {note.canceled_at && (
          <p className={styles.warning}>
            Nota cancelada na Sefaz em {dateTimeText(note.canceled_at)}. O estoque foi desfeito
            {note.kind === "purchase" && " e o custo da compra, estornado se ainda era o que valia"}.
          </p>
        )}
        <p>
          <strong>Emissão:</strong> {dateTimeText(note.emitted_at)} · <strong>Filial:</strong> {note.branch_name}
          {note.counterpart_branch_name && (
            <>
              {" "}
              → <strong>{note.counterpart_branch_name}</strong>
            </>
          )}{" "}
          · {note.kind === "transfer" ? "saiu de uma e entrou na outra" : entry ? "entrou no estoque" : "saiu do estoque"}
        </p>
        <p>
          <strong>{entry ? "Emitente" : "Destinatário"}:</strong>{" "}
          {note.supplier_id && (can(user, "purchases.view") || can(user, "purchases.manage")) ? (
            <Link href={`/fornecedores/${note.supplier_id}`}>{note.supplier_name ?? note.party_name}</Link>
          ) : (
            (note.party_name ?? "—")
          )}{" "}
          <small className={styles.hint}>{documentText(note.party_document)}</small>
        </p>
        <p>
          <strong>Chave:</strong> <small>{note.access_key}</small>
          {note.protocol && (
            <>
              {" "}
              · <strong>Protocolo:</strong> {note.protocol}
            </>
          )}
          {note.cfop && (
            <>
              {" "}
              · <strong>CFOP:</strong> {note.cfop}
            </>
          )}
        </p>
        <p className={styles.hint}>
          Importada em {dateTimeText(note.imported_at)} do arquivo{" "}
          {can(user, "imports.manage") ? <Link href={`/importacoes/${note.import_id}`}>{note.file_name}</Link> : note.file_name}
          . <a href={`/notas-importadas/${note.id}/xml`}>Baixar o XML</a>
        </p>
      </section>

      <section className={styles.card}>
        <h2>Itens</h2>
        <p className={styles.hint}>
          A quantidade do estoque já considera o fracionamento (por exemplo, uma caixa com 10 unidades). Lote e validade
          ficam registrados, sem virar saldo por lote.
        </p>
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Produto</th>
                <th>Código do fornecedor</th>
                <th>Na nota</th>
                <th>No estoque</th>
                <th>Total</th>
                <th>Custo unitário</th>
                <th>CFOP</th>
                <th>Lotes</th>
              </tr>
            </thead>
            <tbody>
              {note.items.map((item) => (
                <tr key={item.line}>
                  <td>{item.line}</td>
                  <td>
                    <Link href={`/produtos/${item.product_id}`}>{item.product_name}</Link>
                    <small className={styles.hint}> · {item.product_code}</small>
                  </td>
                  <td>{item.supplier_code ?? "—"}</td>
                  <td>
                    {quantityText(item.note_quantity)} {item.unit ?? ""}
                  </td>
                  <td>{quantityText(item.quantity)}</td>
                  <td>{brl(item.total)}</td>
                  <td>{item.unit_cost === null ? "—" : brl(item.unit_cost)}</td>
                  <td>{item.cfop ?? "—"}</td>
                  <td>
                    {item.batches.length === 0
                      ? "—"
                      : item.batches.map((batch, index) => (
                          <small key={index} className={styles.hint}>
                            {batch.number ?? "?"} · {batch.quantity === null ? "?" : quantityText(batch.quantity)} · val.{" "}
                            {dayText(batch.expires_on)}
                            <br />
                          </small>
                        ))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>
          <strong>Total da nota: {brl(note.total)}</strong>
        </p>
      </section>
    </>
  );
}
