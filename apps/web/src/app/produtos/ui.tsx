"use client";

import {
  FormEvent,
  startTransition,
  useActionState,
  useEffect,
  useRef,
} from "react";
import { ErrorNotice } from "../error-notice";
import {
  addBarcode,
  changeBarcode,
  changeEntry,
  createEntry,
  createProduct,
  ProductFormState,
  updateProduct,
} from "./actions";
import styles from "../terminais/page.module.css";

export interface CategoryRow {
  id: string;
  parent_id: string | null;
  level: number;
  name: string;
}

export interface GroupRow {
  id: string;
  kind: "commission" | "pricing" | "price_family";
  name: string;
}

export interface ChannelRow {
  id: string;
  name: string;
}

export interface ProductStructure {
  categories: CategoryRow[];
  groups: GroupRow[];
  channels: ChannelRow[];
  units: UnitRow[];
}

/** Unidade de medida da lista fixa do banco. */
export interface UnitRow {
  code: string;
  name: string;
  fractional: boolean;
}

export interface ProductValues {
  id?: string;
  catalog_product_id?: string | null;
  display_name?: string;
  own_manufacturer?: string | null;
  category_id?: string | null;
  commission_group_id?: string | null;
  pricing_group_id?: string | null;
  price_family_id?: string | null;
  uses_pmc?: boolean;
  online_sale_blocked?: boolean;
  fraction_quantity?: string | number;
  unit?: string;
}

export interface BarcodeRow {
  id: string;
  code: string;
  is_internal: boolean;
  is_primary: boolean;
  sends_to_supplier: boolean;
  scan_enabled: boolean;
  fraction_quantity: string | null;
  effective_fraction: string;
  channels: string[];
}

/**
 * O React limpa o formulário ao terminar uma action, e um erro faria a pessoa perder o que digitou.
 * Enviar pelo onSubmit evita isso. O botão clicado continua indo junto, para saber a intenção.
 */
export const keepValues =
  (action: (data: FormData) => void) => (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const submitter = (event.nativeEvent as SubmitEvent).submitter;
    const data = new FormData(event.currentTarget, submitter);
    startTransition(() => action(data));
  };

/** O banco devolve 1.000, que em português se lê como mil. */
const fractionText = (value: string | number | null | undefined) =>
  value === null || value === undefined
    ? ""
    : Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3, useGrouping: false });

/** Só a subcategoria pode ser escolhida, mostrando o caminho inteiro. */
function subcategoryOptions(categories: CategoryRow[]) {
  const byId = new Map(categories.map((category) => [category.id, category]));
  const path = (category: CategoryRow): string => {
    const parent = category.parent_id ? byId.get(category.parent_id) : undefined;
    return parent ? `${path(parent)} > ${category.name}` : category.name;
  };
  return categories
    .filter((category) => category.level === 3)
    .map((category) => ({ id: category.id, label: path(category) }))
    .sort((a, b) => a.label.localeCompare(b.label, "pt-BR"));
}

function GroupSelect({
  label,
  name,
  kind,
  groups,
  value,
  disabled,
}: {
  label: string;
  name: string;
  kind: GroupRow["kind"];
  groups: GroupRow[];
  value?: string | null;
  disabled?: boolean;
}) {
  return (
    <label>
      {label}
      <select name={name} defaultValue={value ?? ""} disabled={disabled}>
        <option value="">Nenhum</option>
        {groups
          .filter((group) => group.kind === kind)
          .map((group) => (
            <option key={group.id} value={group.id}>
              {group.name}
            </option>
          ))}
      </select>
    </label>
  );
}

function ProductFields({
  values,
  structure,
  hasCatalog,
  disabled,
}: {
  values: ProductValues;
  structure: ProductStructure;
  hasCatalog: boolean;
  disabled?: boolean;
}) {
  return (
    <>
      <div className={styles.inline}>
        <label>
          Nome de exibição
          <input
            name="displayName"
            required
            maxLength={200}
            size={50}
            defaultValue={values.display_name ?? ""}
            disabled={disabled}
          />
        </label>
        {!hasCatalog && (
          <label>
            Fabricante
            <input
              name="ownManufacturer"
              maxLength={200}
              defaultValue={values.own_manufacturer ?? ""}
              disabled={disabled}
            />
          </label>
        )}
      </div>
      <div className={styles.inline}>
        <label>
          Subcategoria
          <select
            name="categoryId"
            defaultValue={values.category_id ?? ""}
            disabled={disabled}
          >
            <option value="">Nenhuma</option>
            {subcategoryOptions(structure.categories).map((option) => (
              <option key={option.id} value={option.id}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        <GroupSelect
          label="Grupo de comissão"
          name="commissionGroupId"
          kind="commission"
          groups={structure.groups}
          value={values.commission_group_id}
          disabled={disabled}
        />
        <GroupSelect
          label="Grupo de precificação"
          name="pricingGroupId"
          kind="pricing"
          groups={structure.groups}
          value={values.pricing_group_id}
          disabled={disabled}
        />
        <GroupSelect
          label="Grupo de preço (família)"
          name="priceFamilyId"
          kind="price_family"
          groups={structure.groups}
          value={values.price_family_id}
          disabled={disabled}
        />
      </div>
      <div className={styles.inline}>
        <label>
          Unidade
          <select name="unit" defaultValue={values.unit ?? "UN"} disabled={disabled}>
            {structure.units.map((unit) => (
              <option key={unit.code} value={unit.code}>
                {unit.code} · {unit.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Fracionamento
          <input
            name="fractionQuantity"
            inputMode="decimal"
            size={8}
            defaultValue={fractionText(values.fraction_quantity ?? 1)}
            disabled={disabled}
          />
        </label>
        <label className={styles.check}>
          <input
            type="checkbox"
            name="usesPmc"
            defaultChecked={values.uses_pmc ?? false}
            disabled={disabled}
          />
          Respeita PMC
        </label>
        <label className={styles.check}>
          <input
            type="checkbox"
            name="onlineSaleBlocked"
            defaultChecked={values.online_sale_blocked ?? false}
            disabled={disabled}
          />
          Bloquear venda online
        </label>
      </div>
    </>
  );
}

export function CreateProductForm({
  values,
  catalogBarcodes,
  structure,
}: {
  values: ProductValues;
  catalogBarcodes: string[];
  structure: ProductStructure;
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    createProduct,
    {},
  );
  const hasCatalog = Boolean(values.catalog_product_id);

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      {hasCatalog && (
        <input type="hidden" name="catalogProductId" value={values.catalog_product_id ?? ""} />
      )}
      <ProductFields values={values} structure={structure} hasCatalog={hasCatalog} />
      <div className={styles.inline}>
        {catalogBarcodes.length > 0 ? (
          <label>
            Código de barras principal
            <select name="barcode" defaultValue={catalogBarcodes[0]}>
              {catalogBarcodes.map((code) => (
                <option key={code} value={code}>
                  {code}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <>
            <label>
              Código de barras principal
              <input name="barcode" required maxLength={30} />
            </label>
            <label className={styles.check}>
              <input type="checkbox" name="barcodeIsInternal" />
              Código interno da loja
            </label>
          </>
        )}
      </div>
      {catalogBarcodes.length > 1 && (
        <p className={styles.hint}>
          Os outros códigos deste item também entram no cadastro, se ainda não
          estiverem em outro produto.
        </p>
      )}
      <div>
        <button type="submit" disabled={pending}>
          Confirmar cadastro
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function EditProductForm({
  values,
  structure,
  canManage,
  linkingTo,
}: {
  values: ProductValues;
  structure: ProductStructure;
  canManage: boolean;
  linkingTo?: string | null;
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    updateProduct,
    {},
  );
  const catalogId = linkingTo ?? values.catalog_product_id ?? "";

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="id" value={values.id} />
      <input type="hidden" name="catalogProductId" value={catalogId} />
      {linkingTo && <input type="hidden" name="linking" value="1" />}
      <ProductFields
        values={values}
        structure={structure}
        hasCatalog={Boolean(catalogId)}
        disabled={!canManage}
      />
      {canManage && (
        <div>
          <button type="submit" disabled={pending}>
            {linkingTo ? "Confirmar vínculo e salvar" : "Salvar"}
          </button>
        </div>
      )}
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Produto salvo.
        </p>
      )}
    </form>
  );
}

function BarcodeOptions({
  barcode,
  channels,
  disabled,
}: {
  barcode?: BarcodeRow;
  channels: ChannelRow[];
  disabled?: boolean;
}) {
  return (
    <div className={styles.inline}>
      <label className={styles.check}>
        <input
          type="checkbox"
          name="scanEnabled"
          defaultChecked={barcode?.scan_enabled ?? true}
          disabled={disabled}
        />
        Leitura no PDV
      </label>
      <label className={styles.check}>
        <input
          type="checkbox"
          name="sendsToSupplier"
          defaultChecked={barcode?.sends_to_supplier ?? true}
          disabled={disabled}
        />
        Envia ao fornecedor
      </label>
      {channels.map((channel) => (
        <label key={channel.id} className={styles.check}>
          <input
            type="checkbox"
            name="channels"
            value={channel.id}
            defaultChecked={barcode?.channels.includes(channel.id) ?? false}
            disabled={disabled}
          />
          {channel.name}
        </label>
      ))}
      <label>
        Fracionamento próprio
        <input
          name="fractionQuantity"
          inputMode="decimal"
          size={8}
          placeholder="Do produto"
          defaultValue={fractionText(barcode?.fraction_quantity)}
          disabled={disabled}
        />
      </label>
    </div>
  );
}

export function BarcodeCard({
  productId,
  barcode,
  channels,
  canManage,
}: {
  productId: string;
  barcode: BarcodeRow;
  channels: ChannelRow[];
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    changeBarcode,
    {},
  );

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.device}>
      <input type="hidden" name="id" value={barcode.id} />
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.inline}>
        <strong>{barcode.code}</strong>
        {barcode.is_primary && (
          <span className={`${styles.badge} ${styles.active}`}>Principal</span>
        )}
        {barcode.is_internal && (
          <span className={`${styles.badge} ${styles.offline}`}>Interno</span>
        )}
        <span className={styles.hint}>
          Fracionamento em uso: {fractionText(barcode.effective_fraction)}
        </span>
      </div>
      <BarcodeOptions barcode={barcode} channels={channels} disabled={!canManage} />
      {canManage && (
        <div className={styles.inline}>
          <button type="submit" name="intent" value="save" disabled={pending}>
            Salvar
          </button>
          {!barcode.is_primary && (
            <>
              <button type="submit" name="intent" value="primary" disabled={pending}>
                Tornar principal
              </button>
              <button
                type="submit"
                name="intent"
                value="remove"
                className={styles.danger}
                disabled={pending}
              >
                Remover
              </button>
            </>
          )}
        </div>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function AddBarcodeForm({
  productId,
  channels,
}: {
  productId: string;
  channels: ChannelRow[];
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    addBarcode,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.inline}>
        <label>
          Novo código de barras
          <input name="code" required maxLength={30} />
        </label>
        <label className={styles.check}>
          <input type="checkbox" name="isInternal" />
          Código interno da loja
        </label>
      </div>
      <BarcodeOptions channels={channels} />
      <div>
        <button type="submit" disabled={pending}>
          Adicionar código
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

/** Item da estrutura: renomear e excluir. */
export function EntryRow({
  entity,
  id,
  name,
  canManage,
}: {
  entity: "category" | "group" | "channel";
  id: string;
  name: string;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    changeEntry,
    {},
  );

  if (!canManage) return <p>{name}</p>;

  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="entity" value={entity} />
      <input type="hidden" name="id" value={id} />
      <div className={styles.inline}>
        <input
          name="name"
          required
          maxLength={100}
          defaultValue={name}
          aria-label={`Nome de ${name}`}
        />
        <button type="submit" name="intent" value="rename" disabled={pending}>
          Renomear
        </button>
        <button
          type="submit"
          name="intent"
          value="delete"
          className={styles.danger}
          disabled={pending}
        >
          Excluir
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function AddEntryForm({
  entity,
  label,
  parentId,
  kind,
}: {
  entity: "category" | "group" | "channel";
  label: string;
  parentId?: string;
  kind?: GroupRow["kind"];
}) {
  const [state, action, pending] = useActionState<ProductFormState, FormData>(
    createEntry,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="entity" value={entity} />
      {parentId && <input type="hidden" name="parentId" value={parentId} />}
      {kind && <input type="hidden" name="kind" value={kind} />}
      <div className={styles.inline}>
        <input name="name" required maxLength={100} placeholder={label} aria-label={label} />
        <button type="submit" disabled={pending}>
          Adicionar
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}
