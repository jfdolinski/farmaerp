"use client";

import { getError } from "@farmaerp/error-catalog";
import { FormEvent, useActionState, useEffect, useRef, useState } from "react";
import type { ApiError } from "@/lib/api";
import { ErrorNotice } from "../error-notice";
import { keepValues } from "../produtos/ui";
import { REGIMES } from "./regimes";
import styles from "../terminais/page.module.css";
import {
  copyCertificate,
  FiscalFormState,
  setCsc,
  setDfe,
  setNfce,
  setRegime,
  setSeries,
  setStateRegistration,
  uploadCertificate,
} from "./actions";

export interface FiscalRow {
  company_id: string;
  company_name: string;
  cnpj_root: string;
  tax_regime: number | null;
  branch_id: string;
  branch_name: string;
  branch_cnpj: string;
  state: string | null;
  state_registration: string | null;
  certificate_subject: string | null;
  certificate_cnpj: string | null;
  certificate_valid_to: string | null;
  certificate_days_left: number | null;
  certificate_updated_at: string | null;
  certificate_author: string | null;
  csc_id: string | null;
  csc_updated_at: string | null;
  can_regime: boolean;
  can_manage: boolean;
  can_certificate: boolean;
}

export interface SeriesRow {
  id: string;
  branch_id: string;
  terminal_id: string;
  terminal_number: number;
  terminal_name: string;
  model: "55" | "65";
  series: number;
  initial_number: string;
  last_used_number: string | null;
  can_manage: boolean;
}

// Um A1 tem poucos KB; acima disso não é um certificado, e nem vale a pena enviar.
const MAX_PFX_BYTES = 48_000;

const dateText = (value: string) =>
  new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" });

const Saved = ({ state, text }: { state: FiscalFormState; text: string }) =>
  state.done && !state.error ? (
    <p className={styles.success} role="status">
      {text}
    </p>
  ) : null;

export function RegimeForm({ row }: { row: FiscalRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setRegime, {});
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="companyId" value={row.company_id} />
      <div className={styles.inline}>
        <label>
          Regime tributário
          <select name="regime" required defaultValue={row.tax_regime ?? ""} disabled={!row.can_regime}>
            <option value="" disabled>
              Selecione
            </option>
            {REGIMES.map(([code, label]) => (
              <option key={code} value={code}>
                {label}
              </option>
            ))}
          </select>
        </label>
        {row.can_regime && (
          <button type="submit" disabled={pending}>
            Salvar regime
          </button>
        )}
      </div>
      {!row.can_regime && (
        <p className={styles.hint}>O regime vale para a empresa toda e só muda com permissão em todas as filiais.</p>
      )}
      <ErrorNotice error={state.error} />
      <Saved state={state} text="Regime salvo." />
    </form>
  );
}

export function StateRegistrationForm({ row }: { row: FiscalRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setStateRegistration, {});
  if (!row.state) {
    return <p className={styles.hint}>Inscrição estadual: cadastre antes o estado da filial, em Empresas.</p>;
  }
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.stack}>
      <input type="hidden" name="branchId" value={row.branch_id} />
      <div className={styles.inline}>
        <label>
          Inscrição estadual ({row.state})
          <input
            name="stateRegistration"
            required
            maxLength={30}
            defaultValue={row.state_registration ?? ""}
            disabled={!row.can_manage}
          />
        </label>
        {row.can_manage && (
          <button type="submit" disabled={pending}>
            Salvar inscrição
          </button>
        )}
      </div>
      <ErrorNotice error={state.error} />
      <Saved state={state} text="Inscrição salva." />
    </form>
  );
}

function CertificateStatus({ row }: { row: FiscalRow }) {
  if (!row.certificate_valid_to) {
    return <p className={styles.warning}>Nenhum certificado enviado para esta filial.</p>;
  }
  const days = row.certificate_days_left ?? 0;
  return (
    <div>
      <p>
        <strong>{row.certificate_subject}</strong>
      </p>
      <p className={days <= 30 ? styles.warning : styles.hint}>
        {days < 0
          ? `Venceu em ${dateText(row.certificate_valid_to)}. Envie o certificado novo.`
          : days === 0
            ? "Vence hoje. Envie o certificado novo."
            : `Vale até ${dateText(row.certificate_valid_to)} (${days} dia${days === 1 ? "" : "s"}).`}
      </p>
      {row.certificate_updated_at && (
        <p className={styles.hint}>
          Enviado em {dateText(row.certificate_updated_at)}
          {row.certificate_author ? ` por ${row.certificate_author}` : ""}.
        </p>
      )}
    </div>
  );
}

export function CertificateForm({ row }: { row: FiscalRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(uploadCertificate, {});
  const [tooLarge, setTooLarge] = useState<ApiError>();
  const form = useRef<HTMLFormElement>(null);
  // A senha não fica na tela depois de usada.
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  const send = keepValues(action);
  const submit = (event: FormEvent<HTMLFormElement>) => {
    const file = new FormData(event.currentTarget).get("file");
    if (file instanceof File && file.size > MAX_PFX_BYTES) {
      event.preventDefault();
      setTooLarge({ ...getError("FA912"), traceId: null });
      return;
    }
    setTooLarge(undefined);
    send(event);
  };

  return (
    <>
      <CertificateStatus row={row} />
      {row.can_certificate && (
        <form ref={form} action={action} onSubmit={submit} className={styles.stack} autoComplete="off">
          <input type="hidden" name="branchId" value={row.branch_id} />
          <div className={styles.inline}>
            <label>
              Arquivo do certificado A1 (.pfx)
              <input type="file" name="file" accept=".pfx,.p12" required />
            </label>
            <label>
              Senha do certificado
              <input type="password" name="password" required maxLength={200} autoComplete="new-password" />
            </label>
            <button type="submit" disabled={pending}>
              {pending ? "Enviando..." : "Enviar certificado"}
            </button>
          </div>
          <ErrorNotice error={tooLarge ?? state.error} />
          <Saved state={state} text="Certificado salvo." />
        </form>
      )}
    </>
  );
}

export function CopyCertificateForm({ row, targets }: { row: FiscalRow; targets: FiscalRow[] }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(copyCertificate, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);
  if (!row.can_certificate || !row.certificate_valid_to || targets.length === 0) return null;
  return (
    <details className={styles.reason}>
      <summary>Usar este certificado em outras filiais</summary>
      <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack}>
        <input type="hidden" name="branchId" value={row.branch_id} />
        {targets.map((target) => (
          <label key={target.branch_id} className={styles.check}>
            <input type="checkbox" name="targets" value={target.branch_id} />
            {target.branch_name}
            {target.certificate_valid_to ? " (substitui o atual)" : ""}
          </label>
        ))}
        <div>
          <button type="submit" disabled={pending}>
            Copiar certificado
          </button>
        </div>
        <ErrorNotice error={state.error} />
        <Saved state={state} text="Certificado copiado." />
      </form>
    </details>
  );
}

export function CscForm({ row }: { row: FiscalRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setCsc, {});
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);
  return (
    <>
      <p className={row.csc_id ? styles.hint : styles.warning}>
        {row.csc_id
          ? `Em uso: identificador ${row.csc_id}. O código fica guardado e não é mostrado.`
          : "Nenhum CSC da NFC-e informado para esta filial."}
      </p>
      {row.can_certificate && (
        <form ref={form} action={action} onSubmit={keepValues(action)} className={styles.stack} autoComplete="off">
          <input type="hidden" name="branchId" value={row.branch_id} />
          <div className={styles.inline}>
            <label>
              Identificador do CSC
              <input name="cscId" required maxLength={6} inputMode="numeric" autoComplete="off" />
            </label>
            <label>
              Código CSC
              <input type="password" name="token" required maxLength={36} autoComplete="new-password" />
            </label>
            <button type="submit" disabled={pending}>
              Salvar CSC
            </button>
          </div>
          <ErrorNotice error={state.error} />
          <Saved state={state} text="CSC salvo." />
        </form>
      )}
    </>
  );
}

export function SeriesForm({ row }: { row: SeriesRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setSeries, {});
  const locked = row.last_used_number !== null;
  const editable = row.can_manage && !locked;
  return (
    <form action={action} onSubmit={keepValues(action)} className={styles.device}>
      <input type="hidden" name="id" value={row.id} />
      <p>
        <strong>
          {row.terminal_number} · {row.terminal_name}
        </strong>{" "}
        · {row.model === "65" ? "NFC-e (65)" : "NF-e (55)"}
      </p>
      <div className={styles.inline}>
        <label>
          Série
          <input name="series" required inputMode="numeric" maxLength={3} defaultValue={row.series} disabled={!editable} />
        </label>
        <label>
          Número inicial
          <input
            name="initialNumber"
            required
            inputMode="numeric"
            maxLength={11}
            defaultValue={row.initial_number}
            disabled={!editable}
          />
        </label>
        {editable && (
          <button type="submit" disabled={pending}>
            Salvar série
          </button>
        )}
      </div>
      {locked && <p className={styles.hint}>Já em uso, até o número {row.last_used_number}. Não pode mais mudar.</p>}
      <ErrorNotice error={state.error} />
      <Saved state={state} text="Série salva." />
    </form>
  );
}

/** Liga ou desliga o download automático das notas de compra da filial. */
export function DfeToggle({ branchId, enabled }: { branchId: string; enabled: boolean }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setDfe, {});
  return (
    <form action={action} className={styles.stack}>
      <input type="hidden" name="branchId" value={branchId} />
      <input type="hidden" name="enabled" value={enabled ? "false" : "true"} />
      <div>
        <button type="submit" className={enabled ? styles.danger : undefined} disabled={pending}>
          {enabled ? "Desligar o download automático" : "Ligar o download automático"}
        </button>
      </div>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export interface NfceRow {
  branch_id: string;
  enabled: boolean;
  environment: number;
  contingency_hours: number;
  state_supported: boolean;
  has_state_registration: boolean;
  has_regime: boolean;
  has_certificate: boolean;
  has_csc: boolean;
  terminals: number;
  terminals_ready: number;
  can_manage: boolean;
}

/** "Emitir NFC-e" da filial: requisitos, ambiente, prazo da contingência e os caixas prontos. */
export function NfceForm({ row }: { row: NfceRow }) {
  const [state, action, pending] = useActionState<FiscalFormState, FormData>(setNfce, {});
  const missing = [
    !row.state_supported && "estado ainda não atendido",
    !row.has_state_registration && "inscrição estadual",
    !row.has_regime && "regime da empresa",
    !row.has_certificate && "certificado A1 válido",
    !row.has_csc && "CSC",
  ].filter(Boolean);
  return (
    <>
      <p className={styles.hint}>
        Com a NFC-e ligada, cada caixa recebe o certificado e o CSC criptografados só para ele e emite a nota direto na
        Sefaz. Sem internet, a nota sai em contingência e precisa ser transmitida dentro do prazo; o caixa avisa na metade
        do prazo.
      </p>
      {row.enabled ? (
        <p>
          <strong>Ligada, em {row.environment === 1 ? "produção" : "homologação"}.</strong>{" "}
          {row.terminals === 0
            ? "Nenhum caixa ativo nesta filial."
            : `${row.terminals_ready} de ${row.terminals} ${row.terminals === 1 ? "caixa já recebeu" : "caixas já receberam"} o certificado em uso.`}
        </p>
      ) : (
        <p>
          <strong>Desligada.</strong>
        </p>
      )}
      {missing.length > 0 && (
        <p className={styles.warning}>Para ligar, falta: {missing.join(", ")}.</p>
      )}
      {row.can_manage && (
        <form action={action} className={styles.stack}>
          <input type="hidden" name="branchId" value={row.branch_id} />
          <div className={styles.inline}>
            <label>
              Ambiente
              <select name="environment" defaultValue={String(row.environment)}>
                <option value="2">Homologação (testes, sem valor fiscal)</option>
                <option value="1">Produção</option>
              </select>
            </label>
            <label>
              Prazo da contingência (horas)
              <input
                name="contingencyHours"
                type="number"
                min={1}
                max={168}
                required
                defaultValue={row.contingency_hours}
              />
            </label>
          </div>
          <div className={styles.inline}>
            <button type="submit" name="enabled" value="true" disabled={pending}>
              {row.enabled ? "Salvar" : "Ligar a NFC-e"}
            </button>
            {row.enabled && (
              <button type="submit" name="enabled" value="false" className={styles.danger} disabled={pending}>
                Desligar a NFC-e
              </button>
            )}
          </div>
          <ErrorNotice error={state.error} />
          <Saved state={state} text="Configuração da NFC-e salva." />
        </form>
      )}
    </>
  );
}
