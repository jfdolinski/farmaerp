"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { ErrorNotice } from "../error-notice";
import {
  ActionState,
  approveTerminal,
  changeTerminalStatus,
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
