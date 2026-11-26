import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import styles from "../../terminais/page.module.css";
import { dateTimeText } from "../../vendas/labels";
import { VoidForm } from "../ui";

export const metadata: Metadata = { title: "Inutilização de numeração · FarmaERP" };

interface Gap {
  branch_id: string;
  branch_name: string;
  terminal_id: string;
  terminal_name: string;
  series: number;
  first_number: string;
  last_number: string;
  quantity: string;
  rejected: number;
  safe: boolean;
}

interface VoidRow {
  id: string;
  branch_name: string;
  series: number;
  first_number: string;
  last_number: string;
  reason: string;
  protocol: string;
  voided_at: string;
  requested_by_name: string | null;
}

export default function VoidPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando numeração...</p>}>
        <VoidContent />
      </Suspense>
    </main>
  );
}

async function VoidContent() {
  const user = await requireUser("/notas-fiscais/inutilizacao");
  if (!can(user, "fiscal.void")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Inutilização de numeração</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para inutilizar numeração.</p>
        </section>
      </>
    );
  }
  const [gaps, voids] = await Promise.all([
    apiFetch<Gap[]>("/admin/fiscal-documents/gaps", { timeoutMs: 30_000 }),
    apiFetch<VoidRow[]>("/admin/fiscal-documents/voids"),
  ]);
  if (!gaps.ok) redirectIfNeeded(gaps.error, "/notas-fiscais/inutilizacao");
  const rows = gaps.ok ? gaps.data : [];
  const safe = rows.filter((gap) => gap.safe);
  const unsafe = rows.filter((gap) => !gap.safe);

  const gapCard = (gap: Gap) => (
    <section key={`${gap.terminal_id}-${gap.series}-${gap.first_number}`} className={styles.card}>
      <h3>
        {gap.branch_name} · {gap.terminal_name} · série {gap.series}: números {gap.first_number}
        {gap.last_number !== gap.first_number && ` a ${gap.last_number}`}
      </h3>
      <p className={styles.hint}>
        {gap.quantity} número(s) sem nota válida
        {gap.rejected > 0 && `, ${gap.rejected} de nota rejeitada`}.
      </p>
      <VoidForm branchId={gap.branch_id} series={gap.series} first={Number(gap.first_number)} last={Number(gap.last_number)} safe={gap.safe} />
    </section>
  );

  return (
    <>
      <AppHeader user={user} />
      <h1>Inutilização de numeração</h1>
      <p>
        <Link href="/notas-fiscais">Voltar às notas fiscais</Link>
      </p>
      <p className={styles.hint}>
        Números de NFC-e que ficaram sem nota válida (pulados ou de notas rejeitadas) precisam ser inutilizados na Sefaz.
        Confira cada faixa antes de confirmar: um número inutilizado não pode mais ser usado.
      </p>
      {!gaps.ok && <ErrorNotice error={gaps.error} />}
      {gaps.ok && rows.length === 0 && (
        <section className={styles.card}>
          <p className={styles.hint}>Nenhum buraco de numeração.</p>
        </section>
      )}
      {safe.length > 0 && (
        <>
          <h2>Prontas para inutilizar</h2>
          {safe.map(gapCard)}
        </>
      )}
      {unsafe.length > 0 && (
        <>
          <h2>Aguardando o caixa</h2>
          <p className={styles.warning}>
            O caixa ainda tem itens na fila para a central: estes números podem ser de notas que ainda vão chegar. Prefira
            esperar o caixa sincronizar.
          </p>
          {unsafe.map(gapCard)}
        </>
      )}
      <section className={styles.card}>
        <h2>Inutilizadas</h2>
        {voids.ok && voids.data.length === 0 && <p className={styles.hint}>Nenhuma faixa inutilizada.</p>}
        {voids.ok && voids.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Filial</th>
                  <th>Série</th>
                  <th>Números</th>
                  <th>Motivo</th>
                  <th>Protocolo</th>
                  <th>Quando</th>
                </tr>
              </thead>
              <tbody>
                {voids.data.map((row) => (
                  <tr key={row.id}>
                    <td>{row.branch_name}</td>
                    <td>{row.series}</td>
                    <td>
                      {row.first_number}
                      {row.last_number !== row.first_number && ` a ${row.last_number}`}
                    </td>
                    <td>{row.reason}</td>
                    <td>{row.protocol}</td>
                    <td>
                      {dateTimeText(row.voided_at)}
                      {row.requested_by_name && <small className={styles.hint}> · {row.requested_by_name}</small>}
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
