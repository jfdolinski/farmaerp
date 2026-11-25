"use client";

import { MouseEvent, useActionState, useState } from "react";
import { ErrorNotice } from "../error-notice";
import { RegionSelect, StateSelect } from "../produtos/commercial-ui";
import { keepValues } from "../produtos/ui";
import styles from "../terminais/page.module.css";
import {
  changeBranch,
  changeCompany,
  createBranch,
  createCompany,
  LookupState,
  lookupCnpj,
  moveBranch,
  StructureFormState,
} from "./actions";

export interface CompanyRow {
  id: string;
  legal_name: string;
  trade_name: string;
  cnpj_root: string;
}

export interface BranchRow {
  id: string;
  company_id: string;
  name: string;
  cnpj: string;
  state: string | null;
  pmc_region: string | null;
  postal_code: string | null;
  street: string | null;
  street_number: string | null;
  complement: string | null;
  district: string | null;
  city: string | null;
  city_code: string | null;
  phone: string | null;
}

export type BranchValues = Partial<Omit<BranchRow, "id" | "company_id">>;

const confirmFirst = (message: string) => (event: MouseEvent<HTMLButtonElement>) => {
  if (!window.confirm(message)) event.preventDefault();
};

const cleanCnpj = (value: string) => value.replace(/[^0-9A-Za-z]/g, "").toUpperCase();

/** Conta os envios que deram certo. Na key, devolve o formulário vazio; num erro, o que foi digitado continua. */
function useGeneration(state: StructureFormState) {
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
      <input name={name} defaultValue={initial ?? ""} disabled={disabled} {...rest} />
    </label>
  );
}

function CertificateNotice({ state }: { state: StructureFormState }) {
  return state.certificateEnded ? (
    <p className={styles.warning} role="alert">
      O certificado desta filial foi encerrado. Envie o certificado novo em Fiscal.
    </p>
  ) : null;
}

/** Nome, endereço e estado, iguais na filial nova e na edição. O CNPJ fica por conta de quem chama. */
export function BranchFields({ values, disabled }: { values: BranchValues; disabled?: boolean }) {
  return (
    <>
      <div className={styles.inline}>
        <Field label="Nome da filial" name="name" initial={values.name} required maxLength={150} size={30} disabled={disabled} />
        <Field label="Telefone" name="phone" initial={values.phone} maxLength={20} disabled={disabled} />
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
        <RegionSelect value={values.pmc_region} disabled={disabled} />
      </div>
    </>
  );
}

/** CNPJ da filial, com o aviso quando a raiz é diferente da raiz da empresa. */
function BranchCnpjField({
  initial,
  companyRoot,
  disabled,
}: {
  initial?: string;
  companyRoot: string;
  disabled?: boolean;
}) {
  const [cnpj, setCnpj] = useState(initial ?? "");
  const clean = cleanCnpj(cnpj);
  const otherRoot = clean.length >= 8 && clean.slice(0, 8) !== companyRoot;
  return (
    <>
      <div className={styles.inline}>
        <label>
          CNPJ da filial
          <input
            name="cnpj"
            required
            maxLength={20}
            value={cnpj}
            onChange={(event) => setCnpj(event.target.value)}
            disabled={disabled}
          />
        </label>
      </div>
      {otherRoot && (
        <p className={styles.warning} role="status">
          Esta filial tem outra raiz de CNPJ. O regime tributário será o desta empresa.
        </p>
      )}
    </>
  );
}

export function CreateCompanyForm() {
  const [lookup, lookupAction, looking] = useActionState<LookupState, FormData>(lookupCnpj, {});
  const [state, action, pending] = useActionState<StructureFormState, FormData>(createCompany, {});
  const [withBranch, setWithBranch] = useState(true);
  const generation = useGeneration(state);
  // A consulta usada no cadastro que deu certo não preenche o formulário de novo.
  const [used, setUsed] = useState<LookupState>();
  const [seenGeneration, setSeenGeneration] = useState(generation);
  if (generation !== seenGeneration) {
    setSeenGeneration(generation);
    setUsed(lookup);
  }
  const found = lookup === used ? undefined : lookup;
  const data = found?.data;
  const document = found?.document;

  return (
    <div className={styles.stack}>
      <form key={generation} action={lookupAction} onSubmit={keepValues(lookupAction)} className={styles.device}>
        <div className={styles.inline}>
          <label>
            CNPJ para consultar
            <input name="document" required maxLength={20} defaultValue={document ?? ""} />
          </label>
          <button type="submit" disabled={looking}>
            {looking ? "Consultando..." : "Consultar CNPJ"}
          </button>
        </div>
        <p className={styles.hint}>Preenche os dados pelos serviços públicos da Receita. Confira antes de salvar.</p>
        <ErrorNotice error={found?.error} />
      </form>
      {data && !data.active && (
        <p className={styles.warning} role="alert">
          Atenção: este CNPJ está com a situação {data.statusText ?? "irregular"} na Receita.
        </p>
      )}
      <form
        key={`${document ?? "vazio"}-${generation}`}
        action={action}
        onSubmit={keepValues(action)}
        className={styles.stack}
      >
        <div className={styles.inline}>
          <Field label="CNPJ" name="cnpj" initial={document} required maxLength={20} />
          <Field label="Razão social" name="legalName" initial={data?.legalName} required maxLength={150} size={30} />
          <Field label="Nome fantasia" name="tradeName" initial={data?.tradeName ?? data?.legalName} required maxLength={150} size={30} />
        </div>
        <label className={styles.check}>
          <input
            type="checkbox"
            name="withBranch"
            checked={withBranch}
            onChange={(event) => setWithBranch(event.target.checked)}
          />
          Criar também a filial com este CNPJ
        </label>
        {withBranch && (
          <BranchFields
            values={{
              name: data?.tradeName ?? data?.legalName ?? undefined,
              postal_code: data?.postalCode,
              street: data?.street,
              street_number: data?.streetNumber,
              complement: data?.complement,
              district: data?.district,
              city: data?.city,
              city_code: data?.cityCode,
              state: data?.state,
              phone: data?.phone,
            }}
          />
        )}
        <div>
          <button type="submit" disabled={pending}>
            Criar empresa
          </button>
        </div>
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Empresa criada.
          </p>
        )}
      </form>
    </div>
  );
}

export function CompanyForm({ company, canManage }: { company: CompanyRow; canManage: boolean }) {
  const [state, action, pending] = useActionState<StructureFormState, FormData>(changeCompany, {});
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="id" value={company.id} />
      <p className={styles.hint}>Raiz do CNPJ: {company.cnpj_root}</p>
      <div className={styles.inline}>
        <Field label="Razão social" name="legalName" initial={company.legal_name} required maxLength={150} size={30} disabled={!canManage} />
        <Field label="Nome fantasia" name="tradeName" initial={company.trade_name} required maxLength={150} size={30} disabled={!canManage} />
        {canManage && (
          <>
            <button type="submit" name="intent" value="save" disabled={pending}>
              Salvar empresa
            </button>
            <button
              type="submit"
              name="intent"
              value="delete"
              className={styles.danger}
              disabled={pending}
              onClick={confirmFirst(`Encerrar a empresa ${company.trade_name}?`)}
            >
              Encerrar empresa
            </button>
          </>
        )}
      </div>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Empresa salva.
        </p>
      )}
    </form>
  );
}

export function BranchForm({
  branch,
  companyRoot,
  canManage,
}: {
  branch: BranchRow;
  companyRoot: string;
  canManage: boolean;
}) {
  const [state, action, pending] = useActionState<StructureFormState, FormData>(changeBranch, {});
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="id" value={branch.id} />
      <BranchCnpjField initial={branch.cnpj} companyRoot={companyRoot} disabled={!canManage} />
      <BranchFields values={branch} disabled={!canManage} />
      {canManage && (
        <div className={styles.inline}>
          <button type="submit" name="intent" value="save" disabled={pending}>
            Salvar filial
          </button>
          <button
            type="submit"
            name="intent"
            value="delete"
            className={styles.danger}
            disabled={pending}
            onClick={confirmFirst(
              `Encerrar a filial ${branch.name}? Os vínculos de usuário, o certificado e o CSC dela terminam junto.`,
            )}
          >
            Encerrar filial
          </button>
        </div>
      )}
      <ErrorNotice error={state.error} />
      <CertificateNotice state={state} />
      {state.done && (
        <p className={styles.success} role="status">
          Filial salva.
        </p>
      )}
    </form>
  );
}

export function MoveBranchForm({ branch, companies }: { branch: BranchRow; companies: CompanyRow[] }) {
  const [state, action, pending] = useActionState<StructureFormState, FormData>(moveBranch, {});
  const targets = companies.filter((company) => company.id !== branch.company_id);
  if (targets.length === 0) return null;
  return (
    <details className={styles.reason}>
      <summary>Mover para outra empresa</summary>
      <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <input type="hidden" name="id" value={branch.id} />
        <div className={styles.inline}>
          <label>
            Empresa de destino
            <select name="companyId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {targets.map((company) => (
                <option key={company.id} value={company.id}>
                  {company.trade_name}
                </option>
              ))}
            </select>
          </label>
          <button
            type="submit"
            disabled={pending}
            onClick={confirmFirst(
              `Mover a filial ${branch.name}? Terminais, estoque e preços continuam com ela. O certificado é encerrado e precisa ser enviado de novo.`,
            )}
          >
            Mover filial
          </button>
        </div>
        <p className={styles.hint}>
          Terminais, estoque e preços continuam com a filial. O certificado é encerrado e precisa ser enviado de novo em Fiscal.
        </p>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}

export function CreateBranchForm({ company }: { company: CompanyRow }) {
  const [state, action, pending] = useActionState<StructureFormState, FormData>(createBranch, {});
  const generation = useGeneration(state);
  return (
    <details className={styles.reason}>
      <summary>Nova filial</summary>
      <form key={generation} action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <input type="hidden" name="companyId" value={company.id} />
        <BranchCnpjField companyRoot={company.cnpj_root} />
        <BranchFields values={{}} />
        <div>
          <button type="submit" disabled={pending}>
            Criar filial
          </button>
        </div>
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Filial criada. Vincule os usuários em Usuários.
          </p>
        )}
      </form>
    </details>
  );
}
