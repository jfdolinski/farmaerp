"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import { changeRule, createRule, RuleFormState } from "./actions";
import { dayInput, LEVELS } from "./format";
import styles from "../terminais/page.module.css";

export interface RuleTypeOption {
  code: string;
  name: string;
  unit: string;
  min_value: string;
  max_value: string;
}

export interface NamedOption {
  id: string;
  name: string;
}

export interface CategoryOption extends NamedOption {
  level: number;
  parent_id: string | null;
}

export interface GroupOption extends NamedOption {
  kind: string;
}

export interface RuleRow {
  id: string;
  type_code: string;
  type_name: string;
  unit: string;
  level: string;
  target_name: string | null;
  branch_id: string | null;
  branch_name: string | null;
  value: string;
  priority: number | null;
  valid_from: string;
  valid_to: string | null;
  reason: string | null;
  state: string;
  author: string | null;
  updated_at: string;
}

const CATEGORY_LEVEL: Record<string, number> = { department: 1, category: 2, subcategory: 3 };
const GROUP_KIND: Record<string, string> = {
  price_family: "price_family",
  pricing_group: "pricing",
  commission_group: "commission",
};

/** O caminho inteiro evita confundir categorias de mesmo nome em departamentos diferentes. */
function categoryLabel(category: CategoryOption, categories: CategoryOption[]): string {
  const parent = categories.find((item) => item.id === category.parent_id);
  return parent ? `${categoryLabel(parent, categories)} > ${category.name}` : category.name;
}

function EditableFields({ rule }: { rule?: RuleRow }) {
  return (
    <>
      <label>
        Valor (%)
        <input
          name="value"
          inputMode="decimal"
          required
          size={8}
          defaultValue={rule ? Number(rule.value).toLocaleString("pt-BR", { maximumFractionDigits: 4 }) : ""}
        />
      </label>
      <label>
        Prioridade
        <input
          name="priority"
          inputMode="numeric"
          size={6}
          placeholder="Opcional"
          defaultValue={rule?.priority ?? ""}
        />
      </label>
      <label>
        Início
        <input type="date" name="validFrom" defaultValue={rule ? dayInput(rule.valid_from) : ""} />
      </label>
      <label>
        Fim
        <input type="date" name="validTo" defaultValue={rule ? dayInput(rule.valid_to) : ""} />
      </label>
      <label>
        Motivo
        <input name="reason" maxLength={500} size={30} defaultValue={rule?.reason ?? ""} />
      </label>
    </>
  );
}

export function CreateRuleForm({
  types,
  manufacturers,
  categories,
  groups,
  branches,
}: {
  types: RuleTypeOption[];
  manufacturers: NamedOption[];
  categories: CategoryOption[];
  groups: GroupOption[];
  branches: NamedOption[];
}) {
  const [state, action, pending] = useActionState<RuleFormState, FormData>(createRule, {});
  const [level, setLevel] = useState("store_default");
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  const categoryLevel = CATEGORY_LEVEL[level];
  const groupKind = GROUP_KIND[level];

  return (
    <form
      ref={form}
      action={action}
      onSubmit={keepValues(action)}
      onReset={() => setLevel("store_default")}
      className={styles.stack}
    >
      <div className={styles.inline}>
        <label>
          Tipo
          <select name="typeCode" required>
            {types.map((type) => (
              <option key={type.code} value={type.code}>
                {type.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Vale para
          <select name="level" value={level} onChange={(event) => setLevel(event.target.value)}>
            {LEVELS.map((item) => (
              <option key={item.code} value={item.code}>
                {item.label}
              </option>
            ))}
          </select>
        </label>
        {level === "product" && (
          <label>
            Código ou código de barras
            <input name="productLookup" required maxLength={30} />
          </label>
        )}
        {level === "manufacturer" && (
          <label>
            Fabricante
            <select name="manufacturerId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {manufacturers.map((item) => (
                <option key={item.id} value={item.id}>
                  {item.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {categoryLevel && (
          <label>
            {LEVELS.find((item) => item.code === level)?.label}
            <select key={level} name="categoryId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {categories
                .filter((item) => item.level === categoryLevel)
                .map((item) => (
                  <option key={item.id} value={item.id}>
                    {categoryLabel(item, categories)}
                  </option>
                ))}
            </select>
          </label>
        )}
        {groupKind && (
          <label>
            {LEVELS.find((item) => item.code === level)?.label}
            <select key={level} name="productGroupId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {groups
                .filter((item) => item.kind === groupKind)
                .map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name}
                  </option>
                ))}
            </select>
          </label>
        )}
        <label>
          Onde
          <select name="branchId" defaultValue="">
            <option value="">Rede inteira</option>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className={styles.inline}>
        <EditableFields />
        <button type="submit" disabled={pending}>
          Criar regra
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Regra criada.
        </p>
      )}
    </form>
  );
}

export function EditRuleForm({ rule }: { rule: RuleRow }) {
  const [state, action, pending] = useActionState<RuleFormState, FormData>(changeRule, {});

  return (
    <details className={styles.reason}>
      <summary>Editar</summary>
      <form action={action} onSubmit={keepValues(action)} className={styles.rowForm}>
        <input type="hidden" name="id" value={rule.id} />
        <div className={styles.inline}>
          <EditableFields rule={rule} />
        </div>
        <div className={styles.inline}>
          <button type="submit" name="intent" value="save" disabled={pending}>
            Salvar
          </button>
          <button type="submit" name="intent" value="end" className={styles.danger} disabled={pending}>
            Encerrar regra
          </button>
        </div>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}
