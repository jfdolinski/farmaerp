import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { activeTab, TabItem, Tabs } from "../shell/tabs";
import styles from "../terminais/page.module.css";
import { brl, dateTimeText } from "../vendas/labels";
import { BranchActiveButton, CreateProgramForm, CredentialsForm, ProgramActiveButton, RemoveRuleButton, RuleForm } from "./ui";

export const metadata: Metadata = { title: "PBM · FarmaERP" };

type SearchParams = Promise<{ aba?: string | string[]; de?: string; ate?: string; filial?: string }>;

interface Program {
  id: string;
  name: string;
  connector: string;
  active: boolean;
  can_edit: boolean;
  branches: { branch_id: string; branch_name: string; active: boolean; credentials_set_at: string | null }[];
  rules: { product_id: string; product_code: number; product_name: string; discount_percent: number }[];
}

interface Authorization {
  id: string;
  branch_name: string;
  terminal_name: string;
  program_name: string;
  beneficiary: string;
  external_id: string;
  status: string;
  list_total: number;
  pbm_total: number;
  benefit: number;
  authorized_at: string;
  confirmed_at: string | null;
  sale_number: number | null;
  missing_sale: boolean;
  undo_reason: string | null;
  items: { product_name: string; quantity: number; list_price: number; pbm_price: number }[];
}

const STATUS: Record<string, { label: string; style: string }> = {
  authorized: { label: "Aguardando a venda", style: styles.pending },
  confirmed: { label: "Confirmada", style: styles.active },
  undone: { label: "Desfeita", style: styles.offline },
  expired: { label: "Expirada", style: styles.offline },
};

const DAY = /^\d{4}-\d{2}-\d{2}$/;

export default function PbmPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando o PBM...</p>}>
        <PbmContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function PbmContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/pbm");
  const canManage = can(user, "pbm.manage");
  const canView = can(user, "sales.view");
  const tabs: TabItem[] = [
    canManage && { id: "programas", label: "Programas" },
    canView && { id: "autorizacoes", label: "Autorizações" },
  ].filter((item): item is TabItem => !!item);
  if (tabs.length === 0) {
    return (
      <>
        <AppHeader user={user} />
        <h1>PBM</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os programas de benefício.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const tab = activeTab(tabs, params.aba);
  const from = params.de && DAY.test(params.de) ? params.de : "";
  const to = params.ate && DAY.test(params.ate) ? params.ate : "";
  const branch = params.filial ?? "";
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (to) query.set("to", to);
  if (branch) query.set("branch", branch);
  const [programs, authorizations, branches] = await Promise.all([
    tab === "programas" ? apiFetch<Program[]>("/admin/pbm/programs") : null,
    tab === "autorizacoes" ? apiFetch<Authorization[]>(`/admin/pbm/authorizations?${query.toString()}`) : null,
    tab === "autorizacoes" ? apiFetch<{ id: string; name: string }[]>("/admin/branches") : null,
  ]);
  const first = programs ?? authorizations;
  if (first && !first.ok) redirectIfNeeded(first.error, "/pbm");

  return (
    <>
      <AppHeader user={user} />
      <h1>PBM</h1>
      <p className={styles.hint}>
        Programas de benefício em medicamentos. O caixa consulta o programa pela central, com internet; sem conexão, a venda
        segue pelo preço normal. O desconto do programa vale sozinho no item.
      </p>
      <Tabs base="/pbm" items={tabs} active={tab}>
        {tab === "programas" && programs && (
          <>
            {!programs.ok && <ErrorNotice error={programs.error} />}
            <section className={styles.card}>
              <h2>Novo programa</h2>
              <p className={styles.hint}>
                Por enquanto só há o programa de teste, para treino e homologação. Os programas reais entram quando houver
                contrato com cada um. No de teste, o CPF ou cartão terminado em 0 não tem direito e o que começa com FORA
                simula o programa fora do ar.
              </p>
              <CreateProgramForm />
            </section>
            {programs.ok && programs.data.length === 0 && (
              <section className={styles.card}>
                <p className={styles.hint}>Nenhum programa cadastrado.</p>
              </section>
            )}
            {programs.ok &&
              programs.data.map((program) => (
                <section key={program.id} className={styles.card}>
                  <h2>
                    {program.name}{" "}
                    <span className={`${styles.badge} ${program.active ? styles.active : styles.offline}`}>
                      {program.active ? "Ligado" : "Desligado"}
                    </span>
                  </h2>
                  <p className={styles.hint}>Conector: {program.connector === "test" ? "programa de teste" : program.connector}</p>
                  {program.can_edit && <ProgramActiveButton id={program.id} active={program.active} />}

                  <h3>Lojas</h3>
                  <div className={styles.tableWrap}>
                    <table>
                      <thead>
                        <tr>
                          <th>Loja</th>
                          <th>Situação</th>
                          <th>Dados de acesso</th>
                          <th />
                        </tr>
                      </thead>
                      <tbody>
                        {program.branches.map((row) => (
                          <tr key={row.branch_id}>
                            <td>{row.branch_name}</td>
                            <td>{row.active ? "Ligado" : "Desligado"}</td>
                            <td>
                              {row.credentials_set_at ? `Informados em ${dateTimeText(row.credentials_set_at)}` : "Não informados"}
                              <CredentialsForm id={program.id} branchId={row.branch_id} />
                            </td>
                            <td>
                              <BranchActiveButton id={program.id} branchId={row.branch_id} active={row.active} />
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>

                  {program.connector === "test" && (
                    <>
                      <h3>Produtos do programa de teste</h3>
                      {program.rules.length === 0 && <p className={styles.hint}>Nenhum produto no programa.</p>}
                      {program.rules.length > 0 && (
                        <div className={styles.tableWrap}>
                          <table>
                            <thead>
                              <tr>
                                <th>Código</th>
                                <th>Produto</th>
                                <th>Desconto</th>
                                <th />
                              </tr>
                            </thead>
                            <tbody>
                              {program.rules.map((rule) => (
                                <tr key={rule.product_id}>
                                  <td>{rule.product_code}</td>
                                  <td>{rule.product_name}</td>
                                  <td>{String(rule.discount_percent).replace(".", ",")}%</td>
                                  <td>{program.can_edit && <RemoveRuleButton id={program.id} productId={rule.product_id} />}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )}
                      {program.can_edit && <RuleForm id={program.id} />}
                    </>
                  )}
                </section>
              ))}
          </>
        )}

        {tab === "autorizacoes" && authorizations && (
          <>
            <section className={styles.card}>
              <form className={styles.inline}>
                <input type="hidden" name="aba" value="autorizacoes" />
                <label>
                  De
                  <input type="date" name="de" defaultValue={from} />
                </label>
                <label>
                  Até
                  <input type="date" name="ate" defaultValue={to} />
                </label>
                <label>
                  Loja
                  <select name="filial" defaultValue={branch}>
                    <option value="">Todas</option>
                    {branches?.ok &&
                      branches.data.map((item) => (
                        <option key={item.id} value={item.id}>
                          {item.name}
                        </option>
                      ))}
                  </select>
                </label>
                <button type="submit">Filtrar</button>
              </form>
            </section>
            {!authorizations.ok && <ErrorNotice error={authorizations.error} />}
            {authorizations.ok && authorizations.data.length === 0 && (
              <section className={styles.card}>
                <p className={styles.hint}>Nenhuma autorização no período.</p>
              </section>
            )}
            {authorizations.ok && authorizations.data.length > 0 && (
              <section className={styles.card}>
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Quando</th>
                        <th>Loja e caixa</th>
                        <th>Programa</th>
                        <th>Beneficiário</th>
                        <th>Itens</th>
                        <th>Preço normal</th>
                        <th>Cliente pagou</th>
                        <th>Benefício</th>
                        <th>Situação</th>
                      </tr>
                    </thead>
                    <tbody>
                      {authorizations.data.map((row) => (
                        <tr key={row.id}>
                          <td>{dateTimeText(row.authorized_at)}</td>
                          <td>
                            {row.branch_name}
                            <small className={styles.hint}> · {row.terminal_name}</small>
                          </td>
                          <td>
                            {row.program_name}
                            <small className={styles.hint}> · {row.external_id}</small>
                          </td>
                          <td>{row.beneficiary}</td>
                          <td>
                            {row.items.map((item) => (
                              <div key={item.product_name}>
                                {item.quantity} × {item.product_name}
                              </div>
                            ))}
                          </td>
                          <td>{brl(row.list_total)}</td>
                          <td>{brl(row.pbm_total)}</td>
                          <td>{brl(row.benefit)}</td>
                          <td>
                            <span className={`${styles.badge} ${STATUS[row.status]?.style ?? ""}`}>{STATUS[row.status]?.label ?? row.status}</span>
                            {row.sale_number !== null && <small className={styles.hint}> · venda {row.sale_number}</small>}
                            {row.missing_sale && <small className={styles.warning}> · a venda ainda não chegou à central</small>}
                            {row.undo_reason && <small className={styles.hint}> · {row.undo_reason}</small>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
            )}
          </>
        )}
      </Tabs>
    </>
  );
}
