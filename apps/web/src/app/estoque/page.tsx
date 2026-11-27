import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { BalanceRow, dayText, MOVEMENT_LABELS, quantityText, REVERSIBLE } from "./format";
import { BranchOption, EditBatchForm, MovementForm, ReverseForm } from "./ui";
import styles from "../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../shell/tabs";

export const metadata: Metadata = { title: "Estoque · FarmaERP" };

const EXPIRING_DAYS = 90;
const OVERVIEW_LIMIT = 200;

type SearchParams = Promise<{
  q?: string | string[];
  filial?: string | string[];
  zerados?: string | string[];
  aba?: string | string[];
}>;

interface MovementRow {
  id: string;
  branch_name: string;
  product_code: string;
  product_name: string;
  batch_number: string | null;
  movement_type: string;
  quantity: string;
  reason: string | null;
  reversal_of: string | null;
  reversed: boolean;
  fefo_override: boolean;
  occurred_at: string;
  author: string | null;
}

const moment = (value: string) =>
  new Date(value).toLocaleString("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "America/Sao_Paulo",
  });

export default function StockPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando estoque...</p>}>
        <StockContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function StockContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/estoque");

  if (!can(user, "stock.view")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Estoque</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver o estoque.</p>
        </section>
      </>
    );
  }

  const params = await searchParams;
  const query = typeof params.q === "string" ? params.q.trim() : "";
  const branchId = typeof params.filial === "string" ? params.filial : "";
  const includeZero = params.zerados === "1";
  const canAdjust = can(user, "stock.adjust");
  const canLoss = can(user, "stock.loss");
  const canTransfer = can(user, "stock.transfer");
  const canEditBatch = can(user, "stock.batch");

  const filters = new URLSearchParams({ q: query });
  if (branchId) filters.set("branch", branchId);
  if (includeZero) filters.set("zerados", "1");

  const tabs: TabItem[] = [
    { id: "saldo", label: "Saldo" },
    { id: "movimentacoes", label: "Movimentações" },
  ];
  const tab = activeTab(tabs, params.aba);
  // Os filtros acompanham a troca de aba: a filial também filtra as movimentações.
  const keep: Record<string, string> = {};
  if (query) keep.q = query;
  if (branchId) keep.filial = branchId;
  if (includeZero) keep.zerados = "1";

  // Só busca o que a aba aberta mostra; a conferência dos saldos vale para todas as abas.
  const [balances, movements, branches, check, destinations] = await Promise.all([
    tab === "saldo" ? apiFetch<BalanceRow[]>(`/admin/stock?${filters.toString()}`) : null,
    tab === "movimentacoes"
      ? apiFetch<MovementRow[]>(`/admin/stock/movements${branchId ? `?branch=${encodeURIComponent(branchId)}` : ""}`)
      : null,
    apiFetch<BranchOption[]>("/admin/branches"),
    apiFetch<{ divergences: number }>("/admin/stock/check"),
    tab === "saldo" && canTransfer ? apiFetch<BranchOption[]>("/admin/stock/destinations") : null,
  ]);
  const main = balances ?? movements ?? branches;
  if (!main.ok) redirectIfNeeded(main.error, "/estoque");
  const branchList = branches.ok ? branches.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Estoque</h1>

      {check.ok && check.data.divergences > 0 && (
        <section className={styles.card}>
          <p className={styles.warning} role="alert">
            Há {check.data.divergences} saldo(s) diferente(s) da soma das movimentações. Informe o suporte.
          </p>
        </section>
      )}

      <Tabs base="/estoque" items={tabs} active={tab} keep={keep}>
        {tab === "saldo" && balances && (
          <>
            {(canAdjust || canLoss || canTransfer) && (
              <section className={styles.card}>
                <h2>Registrar movimentação</h2>
                <MovementForm
                  branches={branchList}
                  canAdjust={canAdjust}
                  canLoss={canLoss}
                  canTransfer={canTransfer}
                  destinations={destinations?.ok ? destinations.data : []}
                />
              </section>
            )}
            <section className={styles.card}>
              <h2>Saldo</h2>
              <form action="/estoque" className={styles.inline}>
                <label>
                  Buscar
                  <input
                    name="q"
                    type="search"
                    size={40}
                    maxLength={200}
                    defaultValue={query}
                    placeholder="Produto, código, código de barras ou lote"
                  />
                </label>
                <label>
                  Filial
                  <select name="filial" defaultValue={branchId}>
                    <option value="">Todas</option>
                    {branchList.map((branch) => (
                      <option key={branch.id} value={branch.id}>
                        {branch.name}
                      </option>
                    ))}
                  </select>
                </label>
                <label className={styles.check}>
                  <input type="checkbox" name="zerados" value="1" defaultChecked={includeZero} />
                  Mostrar zerados
                </label>
                <button type="submit">Buscar</button>
              </form>
              {!balances.ok && <ErrorNotice error={balances.error} />}
              {balances.ok && balances.data.length === 0 && <p className={styles.hint}>Nenhum saldo encontrado.</p>}
              {balances.ok && balances.data.length > 0 && (
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Produto</th>
                        <th>Filial</th>
                        <th>Lote</th>
                        <th>Validade</th>
                        <th>Saldo</th>
                        {canEditBatch && <th>Ações</th>}
                      </tr>
                    </thead>
                    <tbody>
                      {balances.data.map((row) => (
                        <tr key={row.balance_id}>
                          <td>
                            <Link href={`/produtos/${row.product_id}`}>{row.product_name}</Link>
                            <small>Código {row.product_code}</small>
                          </td>
                          <td>{row.branch_name}</td>
                          <td>
                            {row.batch_number ?? "Sem lote"}
                            {row.needs_batch && (
                              <small className={styles.warning}>Este produto exige lote: regularize este saldo</small>
                            )}
                            {row.ms_registration && <small>MS {row.ms_registration}</small>}
                            {row.ms_diverges && (
                              <small className={styles.warning}>MS diferente do Catálogo ({row.base_ms})</small>
                            )}
                          </td>
                          <td>
                            {dayText(row.expires_on)}
                            {row.is_expired && <small className={styles.warning}>Vencido: dê saída como perda</small>}
                            {!row.is_expired && row.days_to_expire !== null && row.days_to_expire <= EXPIRING_DAYS && (
                              <small className={styles.warning}>Vence em {row.days_to_expire} dia(s)</small>
                            )}
                          </td>
                          <td>{quantityText(row.quantity)}</td>
                          {canEditBatch && <td>{row.batch_id && <EditBatchForm key={row.batch_id} row={row} />}</td>}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {balances.ok && balances.data.length === OVERVIEW_LIMIT && (
                <p className={styles.warning} role="status">
                  Mostrando os {OVERVIEW_LIMIT} primeiros. Refine a busca para encontrar outros.
                </p>
              )}
            </section>
          </>
        )}

        {tab === "movimentacoes" && movements && (
          <section className={styles.card}>
            <h2>Últimas movimentações</h2>
            {!movements.ok && <ErrorNotice error={movements.error} />}
            {movements.ok && movements.data.length === 0 && <p className={styles.hint}>Nenhuma movimentação ainda.</p>}
            {movements.ok && movements.data.length > 0 && (
              <div className={styles.tableWrap}>
                <table>
                  <thead>
                    <tr>
                      <th>Quando</th>
                      <th>Produto</th>
                      <th>Filial</th>
                      <th>Tipo</th>
                      <th>Quantidade</th>
                      <th>Motivo</th>
                      {canAdjust && <th>Ações</th>}
                    </tr>
                  </thead>
                  <tbody>
                    {movements.data.map((row) => (
                      <tr key={row.id}>
                        <td>{moment(row.occurred_at)}</td>
                        <td>
                          {row.product_name}
                          {row.batch_number && <small>Lote {row.batch_number}</small>}
                        </td>
                        <td>{row.branch_name}</td>
                        <td>
                          {MOVEMENT_LABELS[row.movement_type] ?? row.movement_type}
                          {row.reversal_of && <small>Estorno</small>}
                          {row.reversed && <small>Estornada</small>}
                          {row.fefo_override && <small className={styles.warning}>Fora da ordem de vencimento</small>}
                        </td>
                        <td>{quantityText(row.quantity)}</td>
                        <td>
                          {row.reason}
                          {row.author && <small>Por {row.author}</small>}
                        </td>
                        {canAdjust && (
                          <td>
                            {REVERSIBLE.includes(row.movement_type) && !row.reversed && !row.reversal_of && (
                              <ReverseForm key={row.id} id={row.id} />
                            )}
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        )}
      </Tabs>
    </>
  );
}
