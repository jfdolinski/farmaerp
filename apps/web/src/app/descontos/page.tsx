import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { dayText, levelLabel } from "../regras/format";
import type { CategoryOption, GroupOption, NamedOption } from "../regras/ui";
import { DiscountRow, discountText, kindLabel, STACKING_LABELS, STATUS_LABELS } from "./format";
import { CashbackPolicy, CashbackPolicyForm } from "../cashback/ui";
import { CreateDiscountForm, CustomerGroupForm, EndDiscountButton, SimulatorForm } from "./ui";
import styles from "../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../shell/tabs";

export const metadata: Metadata = { title: "Descontos · FarmaERP" };

type SearchParams = Promise<{ historico?: string | string[]; aba?: string | string[] }>;

const STATUS_STYLES: Record<string, string> = {
  active: styles.active,
  scheduled: styles.pending,
  expired: styles.offline,
  ended: styles.offline,
};

export default function DiscountsPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando os descontos...</p>}>
        <DiscountsContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function DiscountsContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/descontos");
  const canManage = can(user, "rules.manage");
  const canGroups = can(user, "customers.manage");
  if (!can(user, "rules.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Descontos</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os descontos.</p>
        </section>
      </>
    );
  }
  const params = await searchParams;
  const showHistory = params.historico === "1";
  const tabs: TabItem[] = [
    { id: "descontos", label: "Descontos" },
    { id: "simulador", label: "Simulador" },
    { id: "cashback", label: "Cashback" },
    { id: "grupos", label: "Grupos de clientes" },
  ];
  const tab = activeTab(tabs, params.aba);
  const onList = tab === "descontos";
  const [rules, options, structure, branches, customerGroups, agreements, cashback] = await Promise.all([
    onList ? apiFetch<DiscountRow[]>(`/admin/discount-rules${showHistory ? "?historico=1" : ""}`) : null,
    onList && canManage ? apiFetch<{ manufacturers: NamedOption[] }>("/admin/rule-options") : null,
    onList && canManage
      ? apiFetch<{ categories: CategoryOption[]; groups: GroupOption[] }>("/admin/product-structure")
      : null,
    (onList && canManage) || tab === "simulador" ? apiFetch<NamedOption[]>("/admin/branches") : null,
    (onList && canManage) || tab === "grupos" ? apiFetch<NamedOption[]>("/admin/customer-groups") : null,
    (onList && canManage) || tab === "simulador" ? apiFetch<NamedOption[]>("/admin/agreements") : null,
    tab === "cashback" ? apiFetch<CashbackPolicy>("/admin/cashback-policy") : null,
  ]);
  // Sessão vencida ou senha a trocar levam para fora, qualquer que seja a aba aberta.
  const first = rules ?? branches ?? cashback ?? customerGroups;
  if (first && !first.ok) redirectIfNeeded(first.error, "/descontos");
  const branchList = branches?.ok ? branches.data : [];
  const agreementList = agreements?.ok ? agreements.data.map((item) => ({ id: item.id, name: item.name })) : [];
  const groupList = customerGroups?.ok ? customerGroups.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Descontos</h1>
      <Tabs base="/descontos" items={tabs} active={tab}>
        {tab === "descontos" && rules && (
          <>
            <section className={styles.card}>
              <p className={styles.hint}>
                Descontos automáticos do caixa. Os acumuláveis se somam; entre os exclusivos vale o de maior desconto, e
                ele só fica quando dá mais que a soma dos acumuláveis. O desconto nunca passa do valor do item. O
                desconto manual do caixa (com o limite do operador e a liberação do supervisor) continua por cima
                destes.
              </p>
            </section>

            {canManage && (
              <section className={styles.card}>
                <h2>Novo desconto</h2>
                <CreateDiscountForm
                  manufacturers={options?.ok ? options.data.manufacturers : []}
                  categories={structure?.ok ? structure.data.categories : []}
                  groups={structure?.ok ? structure.data.groups : []}
                  branches={branchList}
                  customerGroups={groupList}
                  agreements={agreementList}
                />
              </section>
            )}

            <section className={styles.card}>
              <div className={styles.header}>
                <h2>{showHistory ? "Descontos e histórico" : "Descontos em vigor e agendados"}</h2>
                <Link href={showHistory ? "/descontos" : "/descontos?historico=1"}>
                  {showHistory ? "Esconder encerrados" : "Mostrar encerrados e vencidos"}
                </Link>
              </div>
              {!rules.ok && <ErrorNotice error={rules.error} />}
              {rules.ok && rules.data.length === 0 && <p className={styles.hint}>Nenhum desconto cadastrado.</p>}
              {rules.ok && rules.data.length > 0 && (
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Desconto</th>
                        <th>Dá</th>
                        <th>Vale para</th>
                        <th>Onde</th>
                        <th>Validade</th>
                        <th>Situação</th>
                        {canManage && <th>Ações</th>}
                      </tr>
                    </thead>
                    <tbody>
                      {rules.data.map((row) => (
                        <tr key={row.id}>
                          <td>
                            <strong>{row.name}</strong>
                            <small>
                              {kindLabel(row.kind)} · {STACKING_LABELS[row.stacking] ?? row.stacking}
                            </small>
                          </td>
                          <td>{discountText(row)}</td>
                          <td>
                            {row.level === "store_default" ? "Todos os produtos" : levelLabel(row.level)}
                            {row.target_name && <small>{row.target_name}</small>}
                          </td>
                          <td>{row.branch_id ? row.branch_name : "Rede inteira"}</td>
                          <td>
                            {dayText(row.valid_from)}
                            <small>{row.valid_to ? `até ${dayText(row.valid_to)}` : "Sem data final"}</small>
                          </td>
                          <td>
                            <span className={`${styles.badge} ${STATUS_STYLES[row.status] ?? ""}`}>
                              {STATUS_LABELS[row.status] ?? row.status}
                            </span>
                            {row.reason && <small>{row.reason}</small>}
                          </td>
                          {canManage && <td>{row.status !== "ended" && <EndDiscountButton id={row.id} />}</td>}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          </>
        )}

        {tab === "simulador" && (
          <section className={styles.card}>
            <h2>Simulador</h2>
            <p className={styles.hint}>Monte uma venda de exemplo e veja quais descontos valem e por quê.</p>
            <SimulatorForm branches={branchList} agreements={agreementList} />
          </section>
        )}

        {tab === "cashback" && cashback && (
          <section className={styles.card}>
            <h2>Cashback</h2>
            <p className={styles.hint}>
              O percentual de cada produto vem das regras (tipo Cashback, em Regras). O cliente só ganha e usa com o
              consentimento de cashback, e só ganha sobre o que pagou sem cashback. O uso no caixa precisa de internet.
            </p>
            {cashback.ok ? <CashbackPolicyForm policy={cashback.data} /> : <ErrorNotice error={cashback.error} />}
          </section>
        )}

        {tab === "grupos" && (
          <section className={styles.card}>
            <h2>Grupos de clientes</h2>
            <p className={styles.hint}>
              Para o desconto por grupo (idosos, funcionários, clínicas...). O grupo de cada cliente fica na ficha dele,
              em Clientes.
            </p>
            {groupList.length === 0 && <p className={styles.hint}>Nenhum grupo ainda.</p>}
            {canGroups ? (
              <div className={styles.stack}>
                {groupList.map((group) => (
                  <CustomerGroupForm key={group.id} group={group} />
                ))}
                <CustomerGroupForm />
              </div>
            ) : (
              <ul className={styles.bullets}>
                {groupList.map((group) => (
                  <li key={group.id}>{group.name}</li>
                ))}
              </ul>
            )}
          </section>
        )}
      </Tabs>
    </>
  );
}
