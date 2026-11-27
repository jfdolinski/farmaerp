import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { dayText, levelLabel, STATE_LABELS, valueText } from "./format";
import { CategoryOption, CreateRuleForm, EditRuleForm, GroupOption, NamedOption, RuleRow, RuleTypeOption } from "./ui";
import styles from "../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../shell/tabs";

export const metadata: Metadata = { title: "Regras · FarmaERP" };

// O mesmo limite de app.list_product_rules.
const RULES_LIMIT = 500;

type SearchParams = Promise<{
  produto?: string | string[];
  filial?: string | string[];
  historico?: string | string[];
  aba?: string | string[];
}>;

interface SimulationRow {
  type_code: string;
  type_name: string;
  unit: string;
  rule_id: string | null;
  value: string | null;
  level: string | null;
  target_name: string | null;
  branch_id: string | null;
  priority: number | null;
  valid_to: string | null;
}

interface Simulation {
  product: { display_name: string; code: string };
  rules: SimulationRow[];
}

const STATE_STYLES: Record<string, string> = {
  active: styles.active,
  scheduled: styles.pending,
  expired: styles.offline,
  ended: styles.offline,
};

export default function RulesPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando regras...</p>}>
        <RulesContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

async function RulesContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/regras");
  const canManage = can(user, "rules.manage");

  if (!can(user, "rules.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Regras</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver as regras.</p>
        </section>
      </>
    );
  }

  const params = await searchParams;
  const productLookup = typeof params.produto === "string" ? params.produto.trim() : "";
  const branchId = typeof params.filial === "string" ? params.filial : "";
  const showHistory = params.historico === "1";
  const seesProducts = can(user, "products.view") || can(user, "products.manage");
  const tabs: TabItem[] = [
    { id: "regras", label: "Regras" },
    { id: "simulador", label: "Simulador" },
  ];
  // Endereço antigo com produto e sem aba (?produto=...) continua abrindo o simulador.
  const tab = activeTab(tabs, params.aba ?? (productLookup ? "simulador" : undefined));
  const onList = tab === "regras";

  const [rules, options, structure, branches, simulation] = await Promise.all([
    onList ? apiFetch<RuleRow[]>(`/admin/rules${showHistory ? "?historico=1" : ""}`) : null,
    onList && canManage
      ? apiFetch<{ types: RuleTypeOption[]; manufacturers: NamedOption[] }>("/admin/rule-options")
      : null,
    onList && canManage
      ? apiFetch<{ categories: CategoryOption[]; groups: GroupOption[] }>("/admin/product-structure")
      : null,
    !onList || canManage ? apiFetch<NamedOption[]>("/admin/branches") : null,
    !onList && productLookup
      ? apiFetch<Simulation>(
          `/admin/rules/simulate?product=${encodeURIComponent(productLookup)}${
            branchId ? `&branch=${encodeURIComponent(branchId)}` : ""
          }`,
        )
      : null,
  ]);
  // Sessão vencida ou senha a trocar levam para fora, qualquer que seja a aba aberta.
  const first = rules ?? branches;
  if (first && !first.ok) redirectIfNeeded(first.error, "/regras");
  const branchList = branches?.ok ? branches.data : [];

  return (
    <>
      <AppHeader user={user} />
      <h1>Regras</h1>

      <Tabs base="/regras" items={tabs} active={tab}>
        {tab === "simulador" && (
          <section className={styles.card}>
            <h2>Simulador</h2>
            <p className={styles.hint}>Veja o que vale para um produto e por quê.</p>
            {!seesProducts && (
              <p className={styles.warning}>Para simular, você também precisa da permissão de ver produtos.</p>
            )}
            <form action="/regras" className={styles.inline}>
              <input type="hidden" name="aba" value="simulador" />
              <label>
                Código ou código de barras
                <input name="produto" required maxLength={30} defaultValue={productLookup} />
              </label>
              <label>
                Filial
                <select name="filial" defaultValue={branchId}>
                  <option value="">Só regras da rede</option>
                  {branchList.map((branch) => (
                    <option key={branch.id} value={branch.id}>
                      {branch.name}
                    </option>
                  ))}
                </select>
              </label>
              <button type="submit">Simular</button>
            </form>
            {simulation && !simulation.ok && <ErrorNotice error={simulation.error} />}
            {simulation?.ok && (
              <>
                <p>
                  <strong>
                    {simulation.data.product.code} · {simulation.data.product.display_name}
                  </strong>
                </p>
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Tipo</th>
                        <th>Vale</th>
                        <th>Por quê</th>
                      </tr>
                    </thead>
                    <tbody>
                      {simulation.data.rules.map((row) => (
                        <tr key={row.type_code}>
                          <td>{row.type_name}</td>
                          <td>{row.value === null ? "Sem regra" : valueText(row.value, row.unit)}</td>
                          <td>
                            {row.rule_id === null
                              ? "Nenhuma regra se aplica a este produto."
                              : `Definido por ${levelLabel(row.level).toLowerCase()}${
                                  row.target_name ? `: ${row.target_name}` : ""
                                }, ${row.branch_id ? "nesta filial" : "na rede inteira"}.`}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </>
            )}
          </section>
        )}

        {tab === "regras" && rules && (
          <>
            {canManage && options?.ok && (
              <section className={styles.card}>
                <h2>Nova regra</h2>
                <p className={styles.hint}>
                  Vale a regra mais específica, do produto ao padrão da loja. No mesmo nível, a da filial vence a da
                  rede, depois a de maior prioridade, depois a mais recente.
                </p>
                <CreateRuleForm
                  types={options.data.types}
                  manufacturers={options.data.manufacturers}
                  categories={structure?.ok ? structure.data.categories : []}
                  groups={structure?.ok ? structure.data.groups : []}
                  branches={branchList}
                />
              </section>
            )}

            <section className={styles.card}>
              <div className={styles.header}>
                <h2>{showHistory ? "Regras e histórico" : "Regras"}</h2>
                <Link href={showHistory ? "/regras" : "/regras?historico=1"}>
                  {showHistory ? "Esconder encerradas" : "Mostrar encerradas"}
                </Link>
              </div>
              {!rules.ok && <ErrorNotice error={rules.error} />}
              {rules.ok && rules.data.length === 0 && <p className={styles.hint}>Nenhuma regra cadastrada ainda.</p>}
              {rules.ok && rules.data.length > 0 && (
                <div className={styles.tableWrap}>
                  <table>
                    <thead>
                      <tr>
                        <th>Tipo</th>
                        <th>Vale para</th>
                        <th>Onde</th>
                        <th>Valor</th>
                        <th>Validade</th>
                        <th>Situação</th>
                        {canManage && <th>Ações</th>}
                      </tr>
                    </thead>
                    <tbody>
                      {rules.data.map((rule) => (
                        <tr key={rule.id}>
                          <td>{rule.type_name}</td>
                          <td>
                            {levelLabel(rule.level)}
                            {rule.target_name && <small>{rule.target_name}</small>}
                          </td>
                          <td>{rule.branch_id ? rule.branch_name : "Rede inteira"}</td>
                          <td>
                            {valueText(rule.value, rule.unit)}
                            {rule.priority !== null && <small>Prioridade {rule.priority}</small>}
                          </td>
                          <td>
                            {dayText(rule.valid_from)}
                            <small>{rule.valid_to ? `até ${dayText(rule.valid_to)}` : "Sem data final"}</small>
                          </td>
                          <td>
                            <span className={`${styles.badge} ${STATE_STYLES[rule.state] ?? ""}`}>
                              {STATE_LABELS[rule.state] ?? rule.state}
                            </span>
                            {rule.reason && <small>{rule.reason}</small>}
                            {rule.author && <small>Por {rule.author}</small>}
                          </td>
                          {canManage && <td>{rule.state !== "ended" && <EditRuleForm key={rule.id} rule={rule} />}</td>}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {rules.ok && rules.data.length === RULES_LIMIT && (
                <p className={styles.warning} role="status">
                  Mostrando as {RULES_LIMIT} primeiras regras. Pode haver outras além destas.
                </p>
              )}
            </section>
          </>
        )}
      </Tabs>
    </>
  );
}
