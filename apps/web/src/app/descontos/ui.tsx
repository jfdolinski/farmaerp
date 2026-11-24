"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import { LEVELS } from "../regras/format";
import type { CategoryOption, GroupOption, NamedOption } from "../regras/ui";
import {
  createDiscount,
  DiscountFormState,
  endDiscount,
  saveCustomerGroup,
  setCustomerGroup,
  simulateDiscounts,
  SimulationState,
} from "./actions";
import { DISCOUNT_KINDS, PAYMENT_METHODS } from "./format";
import styles from "../terminais/page.module.css";

const CATEGORY_LEVEL: Record<string, number> = { department: 1, category: 2, subcategory: 3 };
const GROUP_KIND: Record<string, string> = {
  price_family: "price_family",
  pricing_group: "pricing",
  commission_group: "commission",
};

function categoryLabel(category: CategoryOption, categories: CategoryOption[]): string {
  const parent = categories.find((item) => item.id === category.parent_id);
  return parent ? `${categoryLabel(parent, categories)} > ${category.name}` : category.name;
}

const brl = (cents: number) => (cents / 100).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

function Choose({ name, label, options }: { name: string; label: string; options: NamedOption[] }) {
  return (
    <label>
      {label}
      <select name={name} required defaultValue="">
        <option value="" disabled>
          Selecione
        </option>
        {options.map((item) => (
          <option key={item.id} value={item.id}>
            {item.name}
          </option>
        ))}
      </select>
    </label>
  );
}

export function CreateDiscountForm({
  manufacturers,
  categories,
  groups,
  branches,
  customerGroups,
  agreements,
}: {
  manufacturers: NamedOption[];
  categories: CategoryOption[];
  groups: GroupOption[];
  branches: NamedOption[];
  customerGroups: NamedOption[];
  agreements: NamedOption[];
}) {
  const [state, action, pending] = useActionState<DiscountFormState, FormData>(createDiscount, {});
  const [kind, setKind] = useState("product");
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
      onReset={() => {
        setKind("product");
        setLevel("store_default");
      }}
      className={styles.stack}
    >
      <div className={styles.inline}>
        <label>
          Nome (aparece no caixa)
          <input name="name" required maxLength={80} size={28} />
        </label>
        <label>
          Tipo
          <select name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
            {DISCOUNT_KINDS.map((item) => (
              <option key={item.code} value={item.code}>
                {item.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Combina
          <select name="stacking" defaultValue="cumulative">
            <option value="cumulative">Acumulável (soma com os outros)</option>
            <option value="exclusive">Exclusiva (vale sozinha, se der mais)</option>
          </select>
        </label>
      </div>
      <p className={styles.hint}>{DISCOUNT_KINDS.find((item) => item.code === kind)?.hint}</p>
      <div className={styles.inline}>
        {kind === "buy_x_pay_y" ? (
          <>
            <label>
              Leve
              <input name="buyQuantity" inputMode="numeric" required size={4} />
            </label>
            <label>
              Pague
              <input name="payQuantity" inputMode="numeric" required size={4} />
            </label>
          </>
        ) : (
          <label>
            Desconto (%)
            <input name="percent" inputMode="decimal" required size={6} />
          </label>
        )}
        {kind === "quantity" && (
          <label>
            A partir da unidade
            <input name="minQuantity" inputMode="numeric" required size={4} placeholder="2" />
          </label>
        )}
        {kind === "payment_method" && (
          <label>
            Forma de pagamento
            <select name="paymentMethod" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {Object.entries(PAYMENT_METHODS).map(([code, label]) => (
                <option key={code} value={code}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        )}
        {kind === "customer_group" && <Choose name="customerGroupId" label="Grupo de clientes" options={customerGroups} />}
        {kind === "agreement" && <Choose name="agreementId" label="Convênio" options={agreements} />}
        {kind === "cart_total" && (
          <label>
            Compra a partir de (R$)
            <input name="minTotal" inputMode="decimal" required size={8} />
          </label>
        )}
        {kind === "coupon" && (
          <label>
            Código do cupom
            <input name="coupon" required maxLength={20} size={12} pattern="[A-Za-z0-9]{3,20}" />
          </label>
        )}
      </div>
      <div className={styles.inline}>
        <label>
          Vale para
          <select name="level" value={level} onChange={(event) => setLevel(event.target.value)}>
            {LEVELS.map((item) => (
              <option key={item.code} value={item.code}>
                {item.code === "store_default" ? "Todos os produtos" : item.label}
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
        {level === "manufacturer" && <Choose name="manufacturerId" label="Fabricante" options={manufacturers} />}
        {categoryLevel && (
          <Choose
            key={level}
            name="categoryId"
            label={LEVELS.find((item) => item.code === level)?.label ?? ""}
            options={categories.filter((item) => item.level === categoryLevel).map((item) => ({ id: item.id, name: categoryLabel(item, categories) }))}
          />
        )}
        {groupKind && (
          <Choose
            key={level}
            name="productGroupId"
            label={LEVELS.find((item) => item.code === level)?.label ?? ""}
            options={groups.filter((item) => item.kind === groupKind)}
          />
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
        <label>
          Início
          <input type="date" name="validFrom" />
        </label>
        <label>
          Fim{kind === "promotion" ? "" : " (opcional)"}
          <input type="date" name="validTo" required={kind === "promotion"} />
        </label>
        <label>
          Motivo
          <input name="reason" maxLength={500} size={30} />
        </label>
        <button type="submit" disabled={pending}>
          Criar desconto
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Desconto criado. Chega aos PDVs na próxima sincronização.
        </p>
      )}
    </form>
  );
}

export function EndDiscountButton({ id }: { id: string }) {
  const [state, action, pending] = useActionState<DiscountFormState, FormData>(endDiscount, {});
  return (
    <form action={action}>
      <input type="hidden" name="id" value={id} />
      <button type="submit" className={styles.danger} disabled={pending}>
        Encerrar
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function SimulatorForm({ branches, agreements }: { branches: NamedOption[]; agreements: NamedOption[] }) {
  const [state, action, pending] = useActionState<SimulationState, FormData>(simulateDiscounts, {});
  return (
    <form action={action} className={styles.stack}>
      {[1, 2, 3].map((n) => (
        <div key={n} className={styles.inline}>
          <label>
            Produto {n} (código ou código de barras)
            <input name={`product${n}`} maxLength={30} required={n === 1} />
          </label>
          <label>
            Quantidade
            <input name={`quantity${n}`} inputMode="decimal" size={5} defaultValue="1" />
          </label>
          <label>
            Preço (R$)
            <input name={`price${n}`} inputMode="decimal" size={7} />
          </label>
        </div>
      ))}
      <div className={styles.inline}>
        <label>
          Filial
          <select name="branchId" required defaultValue={branches[0]?.id ?? ""}>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Pagamento
          <select name="paymentMethod" defaultValue="">
            <option value="">Ainda não escolhido</option>
            {Object.entries(PAYMENT_METHODS).map(([code, label]) => (
              <option key={code} value={code}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Convênio
          <select name="agreementId" defaultValue="">
            <option value="">Nenhum</option>
            {agreements.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Cupom
          <input name="coupon" maxLength={20} size={10} />
        </label>
        <button type="submit" disabled={pending}>
          Simular
        </button>
      </div>
      <ErrorNotice error={state.error} />
      {state.lines && (
        <div className={styles.tableWrap}>
          <table>
            <thead>
              <tr>
                <th>Produto</th>
                <th>Valor</th>
                <th>Desconto</th>
                <th>Por quê</th>
              </tr>
            </thead>
            <tbody>
              {state.lines.map((line) => (
                <tr key={line.line}>
                  <td>{line.name}</td>
                  <td>{brl(Math.round(line.quantity * line.unit_price * 100))}</td>
                  <td>{brl(Number(line.total_cents))}</td>
                  <td>
                    {line.applied.length === 0
                      ? "Nenhum desconto automático."
                      : line.applied.map((item) => (
                          <small key={item.rule_id}>
                            {item.name}: {brl(Number(item.amount_cents))}
                          </small>
                        ))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </form>
  );
}

export function CustomerGroupForm({ group }: { group?: NamedOption }) {
  const [state, action, pending] = useActionState<DiscountFormState, FormData>(saveCustomerGroup, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done && !group) form.current?.reset();
  }, [state, group]);
  return (
    <form ref={form} action={action} className={styles.inline}>
      {group && <input type="hidden" name="id" value={group.id} />}
      <label>
        {group ? "Nome" : "Novo grupo"}
        <input name="name" required maxLength={60} defaultValue={group?.name ?? ""} />
      </label>
      <button type="submit" name="intent" value="save" disabled={pending}>
        {group ? "Renomear" : "Criar grupo"}
      </button>
      {group && (
        <button type="submit" name="intent" value="remove" className={styles.danger} disabled={pending} formNoValidate>
          Tirar
        </button>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}

/** Grupo do cliente, na ficha dele (para o desconto por grupo). */
export function CustomerGroupSelect({
  customerId,
  current,
  groups,
  canManage,
}: {
  customerId: string;
  current: string | null;
  groups: NamedOption[];
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<DiscountFormState, FormData>(setCustomerGroup, {});
  return (
    <form action={action} className={styles.inline}>
      <input type="hidden" name="customerId" value={customerId} />
      <label>
        Grupo
        <select name="groupId" defaultValue={current ?? ""} disabled={!canManage}>
          <option value="">Sem grupo</option>
          {groups.map((group) => (
            <option key={group.id} value={group.id}>
              {group.name}
            </option>
          ))}
        </select>
      </label>
      {canManage && (
        <button type="submit" disabled={pending}>
          Salvar grupo
        </button>
      )}
      <ErrorNotice error={state.error} />
      {state.done && <p role="status">Grupo salvo.</p>}
    </form>
  );
}
