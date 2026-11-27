"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { ErrorNotice } from "../error-notice";
import {
  ActionState,
  approveTerminal,
  changeTerminalStatus,
  setOfflineMinutes,
  setSaleSettings,
  setReturnDays,
  setTerminalProfile,
  setUpdateRing,
  claimPairing,
  LookupState,
  lookupPairing,
} from "./actions";
import styles from "./page.module.css";

const REFRESH_INTERVAL_MS = 30_000;
const PLATFORM_LABELS: Record<string, string> = {
  windows: "Windows",
  linux: "Linux",
  android: "Android",
};

/** Mantém o painel atualizado sem recarregar a página. */
export function AutoRefresh() {
  const router = useRouter();
  useEffect(() => {
    const timer = setInterval(() => router.refresh(), REFRESH_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [router]);
  return null;
}

export function AddTerminal({
  branches,
}: {
  branches: { id: string; name: string }[];
}) {
  const [lookup, lookupAction, lookingUp] = useActionState<LookupState, FormData>(
    lookupPairing,
    {},
  );
  const [claim, claimAction, claiming] = useActionState<ActionState, FormData>(
    claimPairing,
    {},
  );
  const [dismissedCode, setDismissedCode] = useState<string>();
  const codeInput = useRef<HTMLInputElement>(null);

  const device =
    lookup.device && lookup.code !== dismissedCode ? lookup.device : undefined;

  // Depois de aceitar, volta para o início, pronto para o próximo terminal.
  useEffect(() => {
    if (claim.done && codeInput.current) {
      codeInput.current.value = "";
      codeInput.current.focus();
    }
  }, [claim]);
  const finished = claim.done && lookup.code === dismissedCode;

  return (
    <section className={styles.card}>
      <h2>Adicionar terminal</h2>
      <p className={styles.hint}>
        Abra o PDV no aparelho novo e digite aqui o código mostrado na tela.
      </p>

      <form action={lookupAction} className={styles.inline}>
        <label>
          Código
          <input
            ref={codeInput}
            name="code"
            defaultValue={lookup.code ?? ""}
            required
            maxLength={9}
            autoComplete="off"
            placeholder="K7M2-XQ9P"
            className={styles.codeInput}
          />
        </label>
        <button type="submit" disabled={lookingUp}>
          {lookingUp ? "Procurando..." : "Procurar aparelho"}
        </button>
      </form>
      <ErrorNotice error={lookup.error} />

      {device && (
        <form
          action={(form) => {
            setDismissedCode(lookup.code);
            claimAction(form);
          }}
          className={styles.device}
        >
          <input type="hidden" name="code" value={lookup.code} />
          <p>
            <strong>Confira se é este o aparelho:</strong>{" "}
            {device.deviceName} ({PLATFORM_LABELS[device.platform] ?? device.platform},
            versão {device.appVersion})
          </p>
          {device.keyStorage === "file" && (
            <p className={styles.warning}>
              Este aparelho guarda a chave em arquivo, com proteção menor, porque
              não tem chaveiro do sistema.
            </p>
          )}
          <div className={styles.inline}>
            <label>
              Filial
              <select name="branchId" required defaultValue="">
                <option value="" disabled>
                  Selecione
                </option>
                {branches.map((branch) => (
                  <option key={branch.id} value={branch.id}>
                    {branch.name}
                  </option>
                ))}
              </select>
            </label>
            <button type="submit" disabled={claiming}>
              Adicionar à filial
            </button>
          </div>
        </form>
      )}
      <ErrorNotice error={claim.error} />
      {finished && !claim.error && (
        <p className={styles.success} role="status">
          Terminal adicionado. Agora aprove-o na lista abaixo.
        </p>
      )}
    </section>
  );
}

export function ApproveForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(
    approveTerminal,
    {},
  );
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="id" value={id} />
      <label>
        Nome
        <input name="name" required maxLength={100} placeholder="Caixa 1" />
      </label>
      <label>
        Perfil
        <select name="profile" required defaultValue="">
          <option value="" disabled>
            Selecione
          </option>
          <option value="quote">Orçamento</option>
          <option value="cashier">Caixa</option>
          <option value="self_service">Autoatendimento</option>
        </select>
      </label>
      <button type="submit" disabled={pending}>
        Aprovar
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

const ACTIONS = {
  block: { label: "Bloquear", confirm: "Confirmar bloqueio", danger: false },
  revoke: {
    label: "Revogar",
    confirm: "Revogar definitivamente",
    danger: true,
  },
} as const;

/** Ações que exigem motivo. Revogar não tem volta, por isso avisa antes. */
export function ReasonAction({
  id,
  action: kind,
  label,
}: {
  id: string;
  action: keyof typeof ACTIONS;
  label?: string;
}) {
  const [state, action, pending] = useActionState<ActionState, FormData>(
    changeTerminalStatus,
    {},
  );
  const config = ACTIONS[kind];
  return (
    <details className={styles.reason}>
      <summary>{label ?? config.label}</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <input type="hidden" name="action" value={kind} />
        {kind === "revoke" && (
          <p className={styles.warning}>
            Não tem volta: o aparelho precisará de um novo cadastro.
          </p>
        )}
        <label>
          Motivo
          <input name="reason" required maxLength={500} />
        </label>
        <button
          type="submit"
          disabled={pending}
          className={config.danger ? styles.danger : undefined}
        >
          {config.confirm}
        </button>
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}

/**
 * Tempo sem sincronizar para o PDV contar como sem internet (a venda com estoque negativo liberada fica
 * registrada com os minutos). A filial tem o padrão; o terminal pode ter uma exceção.
 */
export function OfflineMinutesForm({
  scope,
  id,
  current,
  inherited,
}: {
  scope: "branch" | "terminal";
  id: string;
  current: number | null;
  inherited?: number;
}) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setOfflineMinutes, {});
  return (
    <details className={styles.reason}>
      <summary>
        {scope === "branch"
          ? `Sem internet: após ${current} min`
          : current === null
            ? `Sem internet: ${inherited} min (da filial)`
            : `Sem internet: ${current} min (deste terminal)`}
      </summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="scope" value={scope} />
        <input type="hidden" name="id" value={id} />
        <p className={styles.hint}>
          Com o saldo local zerado, o PDV só vende se estiver sem sincronizar há mais que este tempo, e com a
          autorização do gerente. A venda fica registrada como alerta.
        </p>
        <label>
          Minutos (5 a 1440)
          <input name="minutes" type="number" min={5} max={1440} defaultValue={current ?? undefined} required={scope === "branch"} />
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        {scope === "terminal" && current !== null && (
          <button type="submit" name="inherit" value="1" disabled={pending}>
            Usar o tempo da filial
          </button>
        )}
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">Salvo. Chega ao PDV na próxima sincronização.</p>}
      </form>
    </details>
  );
}

/** Troca o perfil do terminal aprovado: o PDV muda de modo na próxima sincronização. */
export function ProfileForm({ id, current }: { id: string; current: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setTerminalProfile, {});
  return (
    <details className={styles.reason}>
      <summary>Mudar o perfil</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <label>
          Perfil
          <select name="profile" defaultValue={current}>
            <option value="cashier">Caixa</option>
            <option value="quote">Orçamento</option>
            <option value="self_service">Autoatendimento</option>
          </select>
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">Salvo. O PDV muda de modo na próxima sincronização.</p>}
      </form>
    </details>
  );
}

/** Anel de atualização: os terminais de teste recebem a versão nova antes da rede. */
export function UpdateRingForm({ id, current }: { id: string; current: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setUpdateRing, {});
  return (
    <details className={styles.reason}>
      <summary>Atualização: {current === "test" ? "terminal de teste" : "rede"}</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <label>
          Recebe a versão nova
          <select name="ring" defaultValue={current}>
            <option value="test">Primeiro (terminal de teste)</option>
            <option value="general">Depois de liberada para a rede</option>
          </select>
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">Salvo.</p>}
      </form>
    </details>
  );
}

/** Prazo de devolução da filial: depois dele, só com a liberação de outra pessoa com a permissão. */
export function ReturnDaysForm({ id, days }: { id: string; days: number }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setReturnDays, {});
  return (
    <details className={styles.reason}>
      <summary>Devolução: {days === 0 ? "só no dia da venda" : `até ${days} ${days === 1 ? "dia" : "dias"} depois da venda`}</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <p className={styles.hint}>
          Dentro do prazo, quem tem a permissão &ldquo;Fazer devolução&rdquo; faz sozinho. Depois do prazo, a devolução precisa da
          liberação de outra pessoa com a permissão.
        </p>
        <label>
          Prazo em dias (0 a 365)
          <input name="days" type="number" min={0} max={365} defaultValue={days} required />
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">Salvo. Chega ao PDV na próxima sincronização.</p>}
      </form>
    </details>
  );
}

/** Validade do orçamento e PIN do vendedor, por filial. */
export function SaleSettingsForm({ id, days, pin }: { id: string; days: number; pin: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(setSaleSettings, {});
  return (
    <details className={styles.reason}>
      <summary>
        {days === 0 ? "Orçamento vale até o fim do dia" : `Orçamento vale ${days} ${days === 1 ? "dia" : "dias"}`} ·{" "}
        {pin ? "vendedor digita o PIN" : "vendedor só com o código"}
      </summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={id} />
        <p className={styles.hint}>
          A validade conta da data do orçamento e termina no fim do dia (0: só no dia). O vendedor se identifica com o
          código a cada orçamento e a cada venda; com o PIN ligado, ninguém usa o código de outro.
        </p>
        <label>
          Validade em dias (0 a 90)
          <input name="days" type="number" min={0} max={90} defaultValue={days} required />
        </label>
        <label>
          <input name="pin" type="checkbox" value="1" defaultChecked={pin} />
          Exigir o PIN do vendedor
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">Salvo. Chega ao PDV na próxima sincronização.</p>}
      </form>
    </details>
  );
}

export function UnblockButton({ id }: { id: string }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(
    changeTerminalStatus,
    {},
  );
  return (
    <form action={action} className={styles.rowForm}>
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="action" value="unblock" />
      <button type="submit" disabled={pending}>
        Desbloquear
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}
