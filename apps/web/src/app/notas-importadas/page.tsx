import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { documentText, ENTRY_KINDS, KIND_LABELS } from "./labels";

export const metadata: Metadata = { title: "Notas importadas · FarmaERP" };

interface ImportedNoteRow {
  id: string;
  branch_id: string;
  branch_name: string;
  counterpart_branch_name: string | null;
  kind: string;
  series: number;
  number: string;
  emitted_at: string;
  party_document: string | null;
  party_name: string | null;
  supplier_id: string | null;
  total: string;
  item_count: number;
  canceled_at: string | null;
}

type SearchParams = Promise<{ de?: string; ate?: string; filial?: string; natureza?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const dayText = (date: Date) => date.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const daysAgo = (days: number) => dayText(new Date(Date.now() - days * 86_400_000));

export default function ImportedNotesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando notas importadas...</p>}>
        <ImportedNotesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ImportedNotesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/notas-importadas");
  if (!can(user, "stock.view") && !can(user, "purchases.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Notas importadas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver o estoque nem as compras.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : daysAgo(90);
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : daysAgo(0);
  const branch = typeof params.filial === "string" && UUID.test(params.filial) ? params.filial : "";
  const kind = typeof params.natureza === "string" && params.natureza in KIND_LABELS ? params.natureza : "";
  const query = new URLSearchParams({ from, to, ...(branch ? { branch } : {}), ...(kind ? { kind } : {}) });
  const [notes, branches] = await Promise.all([
    apiFetch<ImportedNoteRow[]>(`/admin/imported-notes?${query.toString()}`),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!notes.ok) redirectIfNeeded(notes.error, "/notas-importadas");
  const rows = notes.ok ? notes.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Notas importadas</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          NF-e trazidas do sistema anterior pela <Link href="/importacoes">importação de notas</Link> que mexeram no
          estoque: compras, devoluções, transferências entre filiais e outras entradas e saídas, na data da emissão. As
          vendas em NF-e estão em <Link href="/vendas-importadas">Vendas importadas</Link>.
        </p>
        <form action="/notas-importadas" className={styles.inline}>
          <label>
            De
            <input type="date" name="de" defaultValue={from} />
          </label>
          <label>
            Até
            <input type="date" name="ate" defaultValue={to} />
          </label>
          <label>
            Filial
            <select name="filial" defaultValue={branch}>
              <option value="">Todas</option>
              {(branches.ok ? branches.data : []).map((item) => (
                <option key={item.id} value={item.id}>
                  {item.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Natureza
            <select name="natureza" defaultValue={kind}>
              <option value="">Todas</option>
              {Object.entries(KIND_LABELS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!notes.ok && <ErrorNotice error={notes.error} />}
        {notes.ok && rows.length === 0 && <p className={styles.hint}>Nenhuma nota importada no período.</p>}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Nota</th>
                  <th>Emissão</th>
                  <th>Natureza</th>
                  <th>Filial</th>
                  <th>Outra parte</th>
                  <th>Itens</th>
                  <th>Total</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <Link href={`/notas-importadas/${row.id}`}>
                        NF-e {row.series}/{row.number}
                      </Link>
                      {row.canceled_at && <small className={styles.warning}> Cancelada</small>}
                    </td>
                    <td>{dateTimeText(row.emitted_at)}</td>
                    <td>
                      {KIND_LABELS[row.kind] ?? row.kind}
                      <small className={styles.hint}> · {ENTRY_KINDS.has(row.kind) ? "entrada" : "saída"}</small>
                    </td>
                    <td>
                      {row.branch_name}
                      {row.counterpart_branch_name && <small className={styles.hint}> → {row.counterpart_branch_name}</small>}
                    </td>
                    <td>
                      {row.party_name ?? "—"}
                      <br />
                      <small className={styles.hint}>{documentText(row.party_document)}</small>
                    </td>
                    <td>{row.item_count}</td>
                    <td>{brl(row.total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {notes.ok && rows.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 notas mais recentes. Diminua o período para ver todas.</p>
        )}
      </section>
    </>
  );
}
