"use client";

import Link from "next/link";
import { MouseEvent, useActionState, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { StateSelect } from "../produtos/commercial-ui";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import {
  addProductSupplier,
  changeProductSupplier,
  changeSupplier,
  createSupplier,
  LookupState,
  lookupCnpj,
  SupplierFormState,
} from "./actions";
import { cnpjText, fractionText } from "./format";

export interface SupplierValues {
  cnpj?: string | null;
  legal_name?: string | null;
  trade_name?: string | null;
  state_registration?: string | null;
  phone?: string | null;
  email?: string | null;
  postal_code?: string | null;
  street?: string | null;
  street_number?: string | null;
  complement?: string | null;
  district?: string | null;
  city?: string | null;
  city_code?: string | null;
  state?: string | null;
}

export interface SupplierRow extends SupplierValues {
  id: string;
  cnpj: string;
  legal_name: string;
}

export interface SupplierOption {
  id: string;
  cnpj: string;
  legal_name: string;
}

export interface ProductSupplierRow {
  id: string;
  supplier_id: string;
  supplier_name: string;
  supplier_cnpj: string;
  supplier_code: string;
  fraction_quantity: string | null;
  effective_fraction: string;
}

const confirmFirst = (message: string) => (event: MouseEvent<HTMLButtonElement>) => {
  if (!window.confirm(message)) event.preventDefault();
};

/** Conta os envios que deram certo. Na key, devolve o formulário vazio; num erro, o que foi digitado continua. */
function useGeneration(state: SupplierFormState) {
  const [generation, setGeneration] = useState(0);
  const [seen, setSeen] = useState(state);
  if (state !== seen) {
    setSeen(state);
    if (state.done) setGeneration(generation + 1);
  }
  return generation;
}

function Field({
  label,
  name,
  initial,
  ...rest
}: { label: string; name: string; initial?: string | null } & React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label>
      {label}
      <input name={name} defaultValue={initial ?? ""} {...rest} />
    </label>
  );
}

function SupplierFields({ values, disabled }: { values: SupplierValues; disabled?: boolean }) {
  return (
    <>
      <div className={styles.inline}>
        <Field label="Razão social" name="legalName" initial={values.legal_name} required maxLength={150} size={30} disabled={disabled} />
        <Field label="Nome fantasia" name="tradeName" initial={values.trade_name} maxLength={150} size={30} disabled={disabled} />
        <Field label="Inscrição estadual" name="stateRegistration" initial={values.state_registration} maxLength={20} placeholder="Número ou ISENTO" disabled={disabled} />
      </div>
      <div className={styles.inline}>
        <Field label="Telefone" name="phone" initial={values.phone} maxLength={20} disabled={disabled} />
        <Field label="E-mail" name="email" type="email" initial={values.email} maxLength={200} size={30} disabled={disabled} />
      </div>
      <div className={styles.inline}>
        <Field label="CEP" name="postalCode" initial={values.postal_code} maxLength={10} disabled={disabled} />
        <Field label="Rua" name="street" initial={values.street} maxLength={150} size={30} disabled={disabled} />
        <Field label="Número" name="streetNumber" initial={values.street_number} maxLength={20} disabled={disabled} />
        <Field label="Complemento" name="complement" initial={values.complement} maxLength={100} disabled={disabled} />
      </div>
      <div className={styles.inline}>
        <Field label="Bairro" name="district" initial={values.district} maxLength={100} disabled={disabled} />
        <Field label="Cidade" name="city" initial={values.city} maxLength={100} disabled={disabled} />
        <Field label="Código IBGE da cidade" name="cityCode" initial={values.city_code} maxLength={7} disabled={disabled} />
        <StateSelect value={values.state} disabled={disabled} />
      </div>
      <p className={styles.hint}>A inscrição estadual é conferida pelo estado: informe os dois juntos.</p>
    </>
  );
}

export function CreateSupplierForm() {
  const [lookup, lookupAction, looking] = useActionState<LookupState, FormData>(lookupCnpj, {});
  const [state, action, pending] = useActionState<SupplierFormState, FormData>(createSupplier, {});
  const data = lookup.data;

  return (
    <div className={styles.stack}>
      <form action={lookupAction} onSubmit={keepValues(lookupAction)} className={styles.device}>
        <div className={styles.inline}>
          <label>
            CNPJ para consultar
            <input name="document" required maxLength={20} defaultValue={lookup.document ?? ""} />
          </label>
          <button type="submit" disabled={looking}>
            {looking ? "Consultando..." : "Consultar CNPJ"}
          </button>
        </div>
        <p className={styles.hint}>Preenche os dados pelos serviços públicos da Receita. Confira antes de salvar.</p>
        <ErrorNotice error={lookup.error} />
      </form>
      {data && !data.active && (
        <p className={styles.warning} role="alert">
          Atenção: este CNPJ está com a situação {data.statusText ?? "irregular"} na Receita.
        </p>
      )}
      <form key={lookup.document ?? "vazio"} action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <div className={styles.inline}>
          <Field label="CNPJ" name="cnpj" initial={lookup.document} required maxLength={20} />
        </div>
        <SupplierFields
          values={{
            legal_name: data?.legalName,
            trade_name: data?.tradeName,
            phone: data?.phone,
            postal_code: data?.postalCode,
            street: data?.street,
            street_number: data?.streetNumber,
            complement: data?.complement,
            district: data?.district,
            city: data?.city,
            city_code: data?.cityCode,
            state: data?.state,
          }}
        />
        <p className={styles.hint}>O CNPJ não muda depois do cadastro, porque as notas do fornecedor ficam ligadas a ele.</p>
        <div>
          <button type="submit" disabled={pending}>
            Cadastrar fornecedor
          </button>
        </div>
        <ErrorNotice error={state.error} />
      </form>
    </div>
  );
}

export function SupplierForm({ supplier, canManage }: { supplier: SupplierRow; canManage: boolean }) {
  const [state, action, pending] = useActionState<SupplierFormState, FormData>(changeSupplier, {});
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="id" value={supplier.id} />
      <p className={styles.hint}>CNPJ {cnpjText(supplier.cnpj)}</p>
      <SupplierFields values={supplier} disabled={!canManage} />
      {canManage && (
        <div className={styles.inline}>
          <button type="submit" name="intent" value="save" disabled={pending}>
            Salvar fornecedor
          </button>
          <button
            type="submit"
            name="intent"
            value="delete"
            className={styles.danger}
            disabled={pending}
            onClick={confirmFirst(`Encerrar o fornecedor ${supplier.legal_name}? Os códigos dele nos produtos também serão encerrados.`)}
          >
            Encerrar fornecedor
          </button>
        </div>
      )}
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Fornecedor salvo.
        </p>
      )}
    </form>
  );
}

/** Um código do fornecedor no produto: ajusta o fracionamento ou remove. */
export function ProductSupplierForm({
  row,
  canManage,
  next,
  title,
}: {
  row: { id: string; supplier_code: string; fraction_quantity: string | null; effective_fraction: string };
  canManage: boolean;
  next: string;
  title: React.ReactNode;
}) {
  const [state, action, pending] = useActionState<SupplierFormState, FormData>(changeProductSupplier, {});
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.device}>
      <input type="hidden" name="id" value={row.id} />
      <input type="hidden" name="next" value={next} />
      <div className={styles.inline}>
        {title}
        <span>
          Código <strong>{row.supplier_code}</strong>
        </span>
        <span className={styles.hint}>Fracionamento em uso: {fractionText(row.effective_fraction)}</span>
      </div>
      <div className={styles.inline}>
        <label>
          Fracionamento próprio
          <input
            name="fractionQuantity"
            inputMode="decimal"
            size={8}
            placeholder="Do código de barras"
            defaultValue={fractionText(row.fraction_quantity)}
            disabled={!canManage}
          />
        </label>
        {canManage && (
          <>
            <button type="submit" name="intent" value="save" disabled={pending}>
              Salvar
            </button>
            <button
              type="submit"
              name="intent"
              value="remove"
              className={styles.danger}
              disabled={pending}
              onClick={confirmFirst(`Remover o código ${row.supplier_code}?`)}
            >
              Remover
            </button>
          </>
        )}
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function AddProductSupplierForm({ productId, suppliers }: { productId: string; suppliers: SupplierOption[] }) {
  const [state, action, pending] = useActionState<SupplierFormState, FormData>(addProductSupplier, {});
  const generation = useGeneration(state);
  if (suppliers.length === 0) {
    return (
      <p className={styles.hint}>
        Nenhum fornecedor cadastrado. <Link href="/fornecedores/novo">Cadastrar fornecedor</Link>.
      </p>
    );
  }
  return (
    <form key={generation} action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="productId" value={productId} />
      <div className={styles.inline}>
        <label>
          Fornecedor
          <select name="supplierId" required defaultValue="">
            <option value="">Selecione</option>
            {suppliers.map((supplier) => (
              <option key={supplier.id} value={supplier.id}>
                {supplier.legal_name} · {cnpjText(supplier.cnpj)}
              </option>
            ))}
          </select>
        </label>
        <label>
          Código do fornecedor
          <input name="supplierCode" required maxLength={60} size={16} />
        </label>
        <label>
          Fracionamento próprio
          <input name="fractionQuantity" inputMode="decimal" size={8} placeholder="Do código de barras" />
        </label>
        <button type="submit" disabled={pending}>
          Ligar código
        </button>
      </div>
      <p className={styles.hint}>
        Use o código como vem na nota do fornecedor. O fracionamento próprio vale só para as compras com este código.
      </p>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Código ligado ao produto.
        </p>
      )}
    </form>
  );
}
