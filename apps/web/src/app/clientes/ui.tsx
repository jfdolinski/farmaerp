"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import {
  changeAgreement,
  changeCustomerAgreement,
  changeDependent,
  CnpjData,
  createCustomer,
  CustomerFormState,
  lookupCnpj,
  LookupState,
  recordConsent,
  updateCustomer,
} from "./actions";
import { CHANNELS, PURPOSES, RELATIONSHIPS, STATES } from "./format";
import styles from "../terminais/page.module.css";

export interface CustomerValues {
  id?: string;
  person_type?: string;
  document?: string;
  name?: string;
  trade_name?: string | null;
  birth_date?: string | null;
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
  state_registration?: string | null;
}

export interface AgreementRow {
  id: string;
  name: string;
  cnpj: string | null;
  customers?: number;
}

export interface CustomerAgreementRow {
  id: string;
  agreement_id: string;
  agreement_name: string;
  registration: string;
  credit_limit: string;
}

export interface DependentRow {
  id: string;
  name: string;
  relationship: string;
  birth_date: string | null;
  cpf: string | null;
}

export interface ConsentRow {
  purpose: string;
  granted: boolean | null;
  channel: string | null;
  decided_at: string | null;
  author: string | null;
}

/** Campo com valor inicial: a pessoa edita livremente, e o valor só vai no envio. */
function Field({
  label,
  name,
  initial,
  disabled,
  ...rest
}: {
  label: string;
  name: string;
  initial?: string | null;
  disabled?: boolean;
} & React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label>
      {label}
      <input
        name={name}
        defaultValue={initial ?? ""}
        disabled={disabled}
        {...rest}
      />
    </label>
  );
}

function CustomerFields({
  values,
  personType,
  disabled,
}: {
  values: CustomerValues;
  personType: string;
  disabled?: boolean;
}) {
  const company = personType === "company";
  return (
    <>
      <div className={styles.inline}>
        <Field
          label={company ? "CNPJ" : "CPF"}
          name="document"
          initial={values.document}
          required
          maxLength={20}
          disabled={disabled}
        />
        <Field
          label={company ? "Razão social" : "Nome"}
          name="name"
          initial={values.name}
          required
          maxLength={150}
          size={40}
          disabled={disabled}
        />
        {company && (
          <Field
            label="Nome fantasia"
            name="tradeName"
            initial={values.trade_name}
            maxLength={150}
            disabled={disabled}
          />
        )}
        {!company && (
          <Field
            label="Nascimento"
            name="birthDate"
            type="date"
            initial={values.birth_date}
            disabled={disabled}
          />
        )}
      </div>
      <div className={styles.inline}>
        <Field
          label="Telefone"
          name="phone"
          initial={values.phone}
          inputMode="tel"
          maxLength={20}
          disabled={disabled}
        />
        <Field
          label="E-mail"
          name="email"
          type="email"
          initial={values.email}
          maxLength={200}
          size={30}
          disabled={disabled}
        />
      </div>
      <div className={styles.inline}>
        <Field
          label="CEP"
          name="postalCode"
          initial={values.postal_code}
          inputMode="numeric"
          maxLength={9}
          size={10}
          disabled={disabled}
        />
        <Field
          label="Rua"
          name="street"
          initial={values.street}
          maxLength={150}
          size={30}
          disabled={disabled}
        />
        <Field
          label="Número"
          name="streetNumber"
          initial={values.street_number}
          maxLength={20}
          size={6}
          disabled={disabled}
        />
        <Field
          label="Complemento"
          name="complement"
          initial={values.complement}
          maxLength={100}
          disabled={disabled}
        />
      </div>
      <div className={styles.inline}>
        <Field
          label="Bairro"
          name="district"
          initial={values.district}
          maxLength={100}
          disabled={disabled}
        />
        <Field
          label="Cidade"
          name="city"
          initial={values.city}
          maxLength={100}
          disabled={disabled}
        />
        <Field
          label="Código IBGE do município"
          name="cityCode"
          initial={values.city_code}
          inputMode="numeric"
          maxLength={7}
          size={8}
          disabled={disabled}
        />
        {company && (
          <Field
            label="Inscrição estadual"
            name="stateRegistration"
            initial={values.state_registration}
            maxLength={20}
            placeholder="Números ou ISENTO"
            disabled={disabled}
          />
        )}
        <label>
          Estado
          <select
            name="state"
            defaultValue={values.state ?? ""}
            disabled={disabled}
          >
            <option value="">Selecione</option>
            {STATES.map((state) => (
              <option key={state} value={state}>
                {state}
              </option>
            ))}
          </select>
        </label>
      </div>
    </>
  );
}

/** O que veio da consulta vira o valor inicial dos campos; a pessoa confere antes de salvar. */
const fromLookup = (document: string, data: CnpjData): CustomerValues => ({
  document,
  name: data.legalName ?? "",
  trade_name: data.tradeName,
  phone: data.phone,
  email: data.email,
  postal_code: data.postalCode,
  street: data.street,
  street_number: data.streetNumber,
  complement: data.complement,
  district: data.district,
  city: data.city,
  city_code: data.cityCode,
  state: data.state,
});

function CnpjLookup({ onFound }: { onFound: (state: LookupState) => void }) {
  const [state, action, pending] = useActionState<LookupState, FormData>(
    lookupCnpj,
    {},
  );
  useEffect(() => {
    if (state.data) onFound(state);
  }, [state, onFound]);

  return (
    <form
      action={action}
      onSubmit={keepValues(action)}
      className={styles.device}
    >
      <div className={styles.inline}>
        <label>
          CNPJ para consultar
          <input
            name="document"
            required
            maxLength={20}
            defaultValue={state.document ?? ""}
          />
        </label>
        <button type="submit" disabled={pending}>
          {pending ? "Consultando..." : "Consultar CNPJ"}
        </button>
      </div>
      <p className={styles.hint}>
        Preenche os dados pelos serviços públicos da Receita. Confira antes de
        salvar.
      </p>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function CreateCustomerForm() {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    createCustomer,
    {},
  );
  const [personType, setPersonType] = useState("individual");
  const [lookup, setLookup] = useState<LookupState>({});
  const values =
    personType === "company" && lookup.data && lookup.document
      ? fromLookup(lookup.document, lookup.data)
      : {};

  return (
    <div className={styles.stack}>
      {personType === "company" && <CnpjLookup onFound={setLookup} />}
      {personType === "company" && lookup.data && !lookup.data.active && (
        <p className={styles.warning} role="alert">
          Atenção: este CNPJ está com a situação{" "}
          {lookup.data.statusText ?? "irregular"} na Receita.
        </p>
      )}
      {personType === "company" && lookup.data && (
        <p className={styles.success} role="status">
          Dados preenchidos pela consulta. Confira antes de cadastrar.
        </p>
      )}
      <form
        action={action}
        onSubmit={keepValues(action)}
        className={styles.stack}
      >
        <div className={styles.inline}>
          <label className={styles.check}>
            <input
              type="radio"
              name="personType"
              value="individual"
              checked={personType === "individual"}
              onChange={() => setPersonType("individual")}
            />
            Pessoa física
          </label>
          <label className={styles.check}>
            <input
              type="radio"
              name="personType"
              value="company"
              checked={personType === "company"}
              onChange={() => setPersonType("company")}
            />
            Pessoa jurídica
          </label>
        </div>
        <CustomerFields
          key={`${personType}-${lookup.document ?? ""}-${lookup.data?.legalName ?? ""}`}
          values={values}
          personType={personType}
        />
        <p className={styles.hint}>
          Só nome e documento são obrigatórios. Peça os demais dados apenas se
          forem necessários.
        </p>
        <div>
          <button type="submit" disabled={pending}>
            Cadastrar cliente
          </button>
        </div>
        <ErrorNotice error={state.error} />
      </form>
    </div>
  );
}

export function CustomerAgreementForm({
  customerId,
  link,
  agreements,
  canManage,
}: {
  customerId: string;
  link?: CustomerAgreementRow;
  agreements: AgreementRow[];
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    changeCustomerAgreement,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done && !link) form.current?.reset();
  }, [state, link]);
  const limitText = link
    ? Number(link.credit_limit).toLocaleString("pt-BR", {
        minimumFractionDigits: 2,
      })
    : "";

  return (
    <form
      ref={form}
      action={action}
      onSubmit={keepValues(action)}
      className={link ? styles.device : styles.stack}
    >
      <input type="hidden" name="customerId" value={customerId} />
      {link && <input type="hidden" name="id" value={link.id} />}
      <div className={styles.inline}>
        {link ? (
          <strong>{link.agreement_name}</strong>
        ) : (
          <label>
            Convênio
            <select name="agreementId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {agreements.map((agreement) => (
                <option key={agreement.id} value={agreement.id}>
                  {agreement.name}
                </option>
              ))}
            </select>
          </label>
        )}
        <Field
          label="Matrícula"
          name="registration"
          initial={link?.registration}
          required
          maxLength={40}
          disabled={!canManage}
        />
        <Field
          label="Limite (R$)"
          name="creditLimit"
          initial={limitText}
          required
          inputMode="decimal"
          size={10}
          disabled={!canManage}
        />
        {canManage && !link && (
          <button type="submit" name="intent" value="add" disabled={pending}>
            Vincular
          </button>
        )}
        {canManage && link && (
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
            >
              Encerrar vínculo
            </button>
          </>
        )}
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function AgreementForm({ agreement }: { agreement?: AgreementRow }) {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    changeAgreement,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done && !agreement) form.current?.reset();
  }, [state, agreement]);

  return (
    <form
      ref={form}
      action={action}
      onSubmit={keepValues(action)}
      className={agreement ? styles.device : styles.stack}
    >
      {agreement && <input type="hidden" name="id" value={agreement.id} />}
      <div className={styles.inline}>
        <Field
          label="Nome"
          name="name"
          initial={agreement?.name}
          required
          maxLength={150}
          size={30}
        />
        <Field
          label="CNPJ da empresa (opcional)"
          name="cnpj"
          initial={agreement?.cnpj}
          maxLength={20}
        />
        {agreement && (
          <span className={styles.hint}>
            {agreement.customers ?? 0} cliente(s)
          </span>
        )}
        {!agreement && (
          <button type="submit" name="intent" value="add" disabled={pending}>
            Criar convênio
          </button>
        )}
        {agreement && (
          <>
            <button type="submit" name="intent" value="save" disabled={pending}>
              Salvar
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
          </>
        )}
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function EditCustomerForm({
  values,
  canManage,
}: {
  values: CustomerValues;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    updateCustomer,
    {},
  );

  return (
    <form
      action={action}
      onSubmit={keepValues(action)}
      className={styles.stack}
    >
      <input type="hidden" name="id" value={values.id} />
      <CustomerFields
        values={values}
        personType={values.person_type ?? "individual"}
        disabled={!canManage}
      />
      {canManage && (
        <div>
          <button type="submit" disabled={pending}>
            Salvar
          </button>
        </div>
      )}
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Cliente salvo.
        </p>
      )}
    </form>
  );
}

function RelationshipSelect({
  value,
  disabled,
}: {
  value?: string;
  disabled?: boolean;
}) {
  return (
    <label>
      Parentesco
      <select
        name="relationship"
        required
        defaultValue={value ?? ""}
        disabled={disabled}
      >
        <option value="" disabled>
          Selecione
        </option>
        {Object.entries(RELATIONSHIPS).map(([key, label]) => (
          <option key={key} value={key}>
            {label}
          </option>
        ))}
      </select>
    </label>
  );
}

export function DependentForm({
  customerId,
  dependent,
  canManage,
}: {
  customerId: string;
  dependent?: DependentRow;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    changeDependent,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done && !dependent) form.current?.reset();
  }, [state, dependent]);

  return (
    <form
      ref={form}
      action={action}
      onSubmit={keepValues(action)}
      className={dependent ? styles.device : styles.stack}
    >
      <input type="hidden" name="customerId" value={customerId} />
      {dependent && <input type="hidden" name="id" value={dependent.id} />}
      <div className={styles.inline}>
        <Field
          label="Nome"
          name="name"
          initial={dependent?.name}
          required
          maxLength={150}
          disabled={!canManage}
        />
        <RelationshipSelect
          value={dependent?.relationship}
          disabled={!canManage}
        />
        <Field
          label="Nascimento"
          name="birthDate"
          type="date"
          initial={dependent?.birth_date}
          disabled={!canManage}
        />
        <Field
          label="CPF (opcional)"
          name="cpf"
          initial={dependent?.cpf}
          maxLength={20}
          disabled={!canManage}
        />
        {canManage && !dependent && (
          <button type="submit" name="intent" value="add" disabled={pending}>
            Incluir dependente
          </button>
        )}
        {canManage && dependent && (
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

export function ConsentForm({
  customerId,
  consent,
  canManage,
}: {
  customerId: string;
  consent: ConsentRow;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<CustomerFormState, FormData>(
    recordConsent,
    {},
  );
  const label = PURPOSES[consent.purpose] ?? consent.purpose;

  return (
    <form
      action={action}
      onSubmit={keepValues(action)}
      className={styles.stack}
    >
      <input type="hidden" name="customerId" value={customerId} />
      <input type="hidden" name="purpose" value={consent.purpose} />
      <div className={styles.inline}>
        <strong>{label}</strong>
        <span
          className={`${styles.badge} ${consent.granted ? styles.active : styles.offline}`}
        >
          {consent.granted === null
            ? "Não perguntado"
            : consent.granted
              ? "Autorizado"
              : "Revogado"}
        </span>
        {canManage && (
          <>
            <label>
              Canal
              <select name="channel" required defaultValue="store">
                {Object.entries(CHANNELS).map(([key, text]) => (
                  <option key={key} value={key}>
                    {text}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="submit"
              name="intent"
              value="grant"
              disabled={pending || consent.granted === true}
            >
              Registrar autorização
            </button>
            <button
              type="submit"
              name="intent"
              value="revoke"
              disabled={pending || consent.granted !== true}
            >
              Registrar revogação
            </button>
          </>
        )}
      </div>
      {consent.purpose === "facial_recognition" && (
        <p className={styles.hint}>
          Só registra a decisão. O sistema não guarda imagem nem biometria.
        </p>
      )}
      <ErrorNotice error={state.error} />
    </form>
  );
}
