import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { dateTimeText } from "../vendas/labels";
import { type CountRow, STATUS_LABELS } from "./labels";
import { NewCountForm } from "./ui";

export const metadata: Metadata = { title: "Inventário de abertura · FarmaERP" };

export default function CountsPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando inventários...</p>}>
        <CountsContent />
      </Suspense>
    </main>
  );
}

async function CountsContent() {
  const user = await requireUser("/inventario");
  if (!can(user, "stock.opening") && !can(user, "stock.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Inventário de abertura</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver o estoque.</p>
        </section>
      </>
    );
  }
  const [counts, branches] = await Promise.all([
    apiFetch<CountRow[]>("/admin/stock-counts"),
    apiFetch<{ id: string; name: string }[]>("/admin/branches"),
  ]);
  if (!counts.ok) redirectIfNeeded(counts.error, "/inventario");
  const rows = counts.ok ? counts.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Inventário de abertura</h1>
      <p className={styles.hint}>
        A contagem da loja inteira para começar com o estoque certo, depois da importação das notas. Conte por planilha
        (pode ser uma por seção: cada uma soma) e corrija digitando. Produto que exige lote é contado por lote, com
        validade. Na conferência você vê o saldo no corte, o contado e a diferença; ao aplicar, o contado vira o saldo e o
        que não foi contado vai a zero. O inventário dos controlados para o SNGPC continua na tela do SNGPC.
      </p>
      {can(user, "stock.opening") && (
        <section className={styles.card}>
          <h2>Novo inventário</h2>
          <NewCountForm branches={branches.ok ? branches.data : []} />
        </section>
      )}
      <section className={styles.card}>
        <h2>Inventários</h2>
        {!counts.ok && <ErrorNotice error={counts.error} />}
        {counts.ok && rows.length === 0 && <p className={styles.hint}>Nenhum inventário ainda.</p>}
        {rows.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Corte</th>
                  <th>Situação</th>
                  <th>Linhas contadas</th>
                  <th>Resultado</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      {row.branch_name}
                      {row.note && <small className={styles.hint}> · {row.note}</small>}
                    </td>
                    <td>{dateTimeText(row.cutoff_at)}</td>
                    <td>{STATUS_LABELS[row.status] ?? row.status}</td>
                    <td>{row.item_count.toLocaleString("pt-BR")}</td>
                    <td>
                      {row.totals
                        ? `${row.totals.raised} acrescentado(s), ${row.totals.lowered} baixado(s), ${row.totals.zeroed} zerado(s)`
                        : "—"}
                    </td>
                    <td>
                      <Link href={`/inventario/${row.id}`}>{row.can_change ? "Continuar" : "Ver"}</Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
