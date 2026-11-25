import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { brl } from "../vendas/labels";
import { dayText } from "./section";
import { Policy, PolicyForm } from "./ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Crediário · FarmaERP" };

interface AccountRow {
  account_id: string;
  customer_id: string;
  customer_code: string;
  customer_name: string;
  home_branch_name: string;
  credit_limit: string;
  status: "active" | "blocked";
  principal_open: string;
  charges_open: string;
  total_open: string;
  available: string;
  overdue_principal: string;
  oldest_due: string | null;
  overdue_days: number;
  blocked_by_overdue: boolean;
}

interface PolicyRow {
  branch_id: string;
  branch_name: string;
  policy: Policy;
  customized: boolean;
  can_edit: boolean;
}

const SITUATIONS = { todos: "all", "com-debito": "debt", atrasados: "overdue", bloqueados: "blocked" } as const;
const SITUATION_LABELS: Record<keyof typeof SITUATIONS, string> = {
  todos: "Todos",
  "com-debito": "Com débito",
  atrasados: "Em atraso",
  bloqueados: "Bloqueados",
};
type SituationKey = keyof typeof SITUATIONS;
type SearchParams = Promise<{ situacao?: string; busca?: string }>;

export default function CreditPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando o crediário...</p>}>
        <CreditContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function CreditContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/crediario");
  if (!can(user, "credit.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Crediário</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver o crediário.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const key: SituationKey = params.situacao && params.situacao in SITUATIONS ? (params.situacao as SituationKey) : "com-debito";
  const search = (params.busca ?? "").trim().slice(0, 100);
  const query = new URLSearchParams({ situation: SITUATIONS[key] });
  if (search) query.set("search", search);
  const [accounts, policies] = await Promise.all([
    apiFetch<AccountRow[]>(`/admin/credit/accounts?${query}`),
    apiFetch<PolicyRow[]>("/admin/credit/policies"),
  ]);
  if (!accounts.ok) redirectIfNeeded(accounts.error, "/crediario");
  const link = (situation: SituationKey) => {
    const next = new URLSearchParams({ situacao: situation });
    if (search) next.set("busca", search);
    return `/crediario?${next}`;
  };

  return (
    <>
      <AppHeader user={user} />
      <h1>Crediário</h1>
      <section className={styles.card}>
        <h2>Contas</h2>
        <p className={styles.hint}>
          O crediário de cada cliente é aberto e ajustado na ficha dele, em Clientes. Os recebimentos são feitos no caixa
          de qualquer loja e abatem primeiro multa e juros, depois a parcela mais antiga.
        </p>
        <nav className={styles.inline} aria-label="Situação">
          {(Object.keys(SITUATIONS) as SituationKey[]).map((item) =>
            item === key ? (
              <strong key={item}>{SITUATION_LABELS[item]}</strong>
            ) : (
              <Link key={item} href={link(item)}>
                {SITUATION_LABELS[item]}
              </Link>
            ),
          )}
        </nav>
        <form className={styles.inline} action="/crediario">
          <input type="hidden" name="situacao" value={key} />
          <label>
            Cliente
            <input name="busca" defaultValue={search} placeholder="Nome ou código" maxLength={100} />
          </label>
          <button type="submit">Buscar</button>
        </form>
        {!accounts.ok && <ErrorNotice error={accounts.error} />}
        {accounts.ok && accounts.data.length === 0 && <p className={styles.hint}>Nenhuma conta nesta lista.</p>}
        {accounts.ok && accounts.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Cliente</th>
                  <th>Limite</th>
                  <th>Em aberto</th>
                  <th>Disponível</th>
                  <th>Vencido</th>
                  <th>Situação</th>
                </tr>
              </thead>
              <tbody>
                {accounts.data.map((row) => (
                  <tr key={row.account_id}>
                    <td>
                      <Link href={`/clientes/${row.customer_id}`}>
                        {row.customer_code} · {row.customer_name}
                      </Link>
                      <small className={styles.hint}> · {row.home_branch_name}</small>
                    </td>
                    <td>{brl(row.credit_limit)}</td>
                    <td>
                      {brl(row.principal_open)}
                      {Number(row.charges_open) > 0 && <small className={styles.hint}> + {brl(row.charges_open)} de encargos</small>}
                    </td>
                    <td>{brl(row.available)}</td>
                    <td>
                      {Number(row.overdue_principal) > 0 ? (
                        <span className={styles.warning}>
                          {brl(row.overdue_principal)} · {row.overdue_days} dias (desde {dayText(row.oldest_due!)})
                        </span>
                      ) : (
                        "—"
                      )}
                    </td>
                    <td>
                      {row.status === "blocked" ? "Bloqueado" : row.blocked_by_overdue ? "Bloqueado pelo atraso" : "Ativo"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {accounts.ok && accounts.data.length >= 500 && (
          <p className={styles.warning}>A lista mostra as 500 primeiras contas. Use a busca.</p>
        )}
      </section>

      <section className={styles.card}>
        <h2>Parâmetros por filial</h2>
        <p className={styles.hint}>
          Valem para as contas da filial. A multa por atraso tem o teto de 2% do Código de Defesa do Consumidor; confirme
          multa e juros com o contador. Mudanças nos vencimentos valem para as compras novas.
        </p>
        {!policies.ok && <ErrorNotice error={policies.error} />}
        {policies.ok &&
          policies.data.map((row) => (
            <div key={row.branch_id} className={styles.device}>
              <strong>
                {row.branch_name}
                {!row.customized && <small className={styles.hint}> · padrão do sistema</small>}
              </strong>
              <PolicyForm branchId={row.branch_id} policy={row.policy} canEdit={row.can_edit} />
            </div>
          ))}
      </section>
    </>
  );
}
