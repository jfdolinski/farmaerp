"use client";

import { useActionState } from "react";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { createProgram, PbmState, setBranchActive, setCredentials, setProgramActive, setRule } from "./actions";

type Action = (previous: PbmState, form: FormData) => Promise<PbmState>;

/** Botão de uma ação só (ligar, desligar, tirar o produto), com o erro logo abaixo. */
function ActionButton({ action, fields, label, pending: pendingLabel }: { action: Action; fields: Record<string, string>; label: string; pending: string }) {
  const [state, run, pending] = useActionState<PbmState, FormData>(action, {});
  return (
    <form action={run}>
      {Object.entries(fields).map(([name, value]) => (
        <input key={name} type="hidden" name={name} value={value} />
      ))}
      <button type="submit" disabled={pending}>
        {pending ? pendingLabel : label}
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function CreateProgramForm() {
  const [state, run, pending] = useActionState<PbmState, FormData>(createProgram, {});
  return (
    <form action={run} className={styles.inline}>
      <label>
        Nome do programa
        <input name="name" required minLength={2} maxLength={80} size={30} />
      </label>
      <button type="submit" disabled={pending}>
        {pending ? "Criando..." : "Criar programa de teste"}
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function ProgramActiveButton({ id, active }: { id: string; active: boolean }) {
  return (
    <ActionButton
      action={setProgramActive}
      fields={{ id, active: String(!active) }}
      label={active ? "Desligar o programa na rede" : "Ligar o programa na rede"}
      pending="Salvando..."
    />
  );
}

export function BranchActiveButton({ id, branchId, active }: { id: string; branchId: string; active: boolean }) {
  return (
    <ActionButton
      action={setBranchActive}
      fields={{ id, branchId, active: String(!active) }}
      label={active ? "Desligar nesta loja" : "Ligar nesta loja"}
      pending="Salvando..."
    />
  );
}

/** Dados de acesso da loja no programa. Gravados cifrados: a tela só diz quando foram informados. */
export function CredentialsForm({ id, branchId }: { id: string; branchId: string }) {
  const [state, run, pending] = useActionState<PbmState, FormData>(setCredentials, {});
  return (
    <details>
      <summary>Informar os dados de acesso</summary>
      <form action={run} className={styles.stack} autoComplete="off">
        <input type="hidden" name="id" value={id} />
        <input type="hidden" name="branchId" value={branchId} />
        <label>
          Usuário
          <input name="usuario" maxLength={500} autoComplete="off" />
        </label>
        <label>
          Senha
          <input name="senha" type="password" maxLength={500} autoComplete="new-password" />
        </label>
        <label>
          Código da loja no programa
          <input name="codigoLoja" maxLength={500} autoComplete="off" />
        </label>
        <p className={styles.hint}>Os dados ficam guardados cifrados na central e não aparecem de novo nesta tela.</p>
        <div className={styles.inline}>
          <button type="submit" disabled={pending}>
            {pending ? "Salvando..." : "Salvar os dados de acesso"}
          </button>
        </div>
        {state.done && !state.error && <p className={styles.success}>Dados de acesso salvos.</p>}
        <ErrorNotice error={state.error} />
      </form>
    </details>
  );
}

export function RuleForm({ id }: { id: string }) {
  const [state, run, pending] = useActionState<PbmState, FormData>(setRule, {});
  return (
    <form action={run} className={styles.inline}>
      <input type="hidden" name="id" value={id} />
      <label>
        Código ou código de barras
        <input name="productLookup" required maxLength={30} size={16} />
      </label>
      <label>
        Desconto (%)
        <input name="percent" required inputMode="decimal" size={6} pattern="[0-9]{1,3}([.,][0-9]{1,2})?" />
      </label>
      <button type="submit" disabled={pending}>
        {pending ? "Salvando..." : "Incluir no programa"}
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function RemoveRuleButton({ id, productId }: { id: string; productId: string }) {
  return <ActionButton action={setRule} fields={{ id, productId, percent: "" }} label="Tirar" pending="Tirando..." />;
}
