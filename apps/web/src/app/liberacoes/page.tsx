import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Liberações · FarmaERP" };

interface ReleaseRow {
  id: string;
  created_at: string;
  branch_name: string;
  action: string;
  limit_name: string;
  unit: "percent" | "money";
  value: string;
  requester_limit: string | null;
  releaser_limit: string | null;
  requested_by_name: string | null;
  released_by_name: string;
  reason: string;
  reference_id: string | null;
}

const ACTIONS: Record<string, string> = {
  "stock.loss": "Perda de estoque",
  "stock.adjust": "Ajuste de estoque",
  "stock.count": "Inventário",
  "purchases.cost": "Custo da nota de compra",
  "sales.discount": "Desconto na venda",
};

type SearchParams = Promise<{ de?: string; ate?: string; acao?: string }>;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

const amount = (row: ReleaseRow, value: string | null) => {
  if (value === null) return "sem limite";
  return row.unit === "percent"
    ? `${Number(value).toLocaleString("pt-BR")}%`
    : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
};
const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

export default function ReleasesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando liberações...</p>}>
        <ReleasesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function ReleasesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/liberacoes");
  if (!can(user, "releases.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Liberações</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as liberações.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const from = typeof params.de === "string" && DAY.test(params.de) ? params.de : "";
  const to = typeof params.ate === "string" && DAY.test(params.ate) ? params.ate : "";
  const action = typeof params.acao === "string" && params.acao in ACTIONS ? params.acao : "";
  const query = new URLSearchParams({
    ...(from ? { from } : {}),
    ...(to ? { to } : {}),
    ...(action ? { action } : {}),
  });
  const result = await apiFetch<ReleaseRow[]>(`/admin/supervisor-releases?${query.toString()}`);
  if (!result.ok) redirectIfNeeded(result.error, "/liberacoes");

  return (
    <>
      <AppHeader user={user} />
      <h1>Liberações</h1>
      <section className={styles.card}>
        <p className={styles.hint}>
          Operações que passaram do limite de quem fazia e foram liberadas por um supervisor presente, e as liberações de
          custo das notas de compra. Os limites de cada perfil ficam em <Link href="/perfis">Perfis</Link>.
        </p>
        <form action="/liberacoes" className={styles.inline}>
          <label>
            De
            <input type="date" name="de" defaultValue={from} />
          </label>
          <label>
            Até
            <input type="date" name="ate" defaultValue={to} />
          </label>
          <label>
            Operação
            <select name="acao" defaultValue={action}>
              <option value="">Todas</option>
              {Object.entries(ACTIONS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Filtrar</button>
        </form>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && result.data.length === 0 && <p className={styles.hint}>Nenhuma liberação no período.</p>}
        {result.ok && result.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Operação</th>
                  <th>Filial</th>
                  <th>Valor</th>
                  <th>Pediu</th>
                  <th>Liberou</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody>
                {result.data.map((row) => (
                  <tr key={row.id}>
                    <td>{dateTimeText(row.created_at)}</td>
                    <td>
                      {ACTIONS[row.action] ?? row.action}
                      {row.action === "purchases.cost" && row.reference_id && (
                        <small>
                          {" "}
                          <Link href={`/notas/${row.reference_id}`}>Ver nota</Link>
                        </small>
                      )}
                    </td>
                    <td>{row.branch_name}</td>
                    <td>
                      {amount(row, row.value)}
                      <small className={styles.hint}>
                        {row.action === "purchases.cost"
                          ? ` · custo médio ${amount(row, row.requester_limit)}`
                          : ` · limite de quem pediu ${amount(row, row.requester_limit)}, de quem liberou ${amount(row, row.releaser_limit)}`}
                      </small>
                    </td>
                    <td>{row.requested_by_name ?? "—"}</td>
                    <td>{row.released_by_name}</td>
                    <td>{row.reason}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {result.ok && result.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 liberações mais recentes. Diminua o período para ver todas.</p>
        )}
      </section>
    </>
  );
}
