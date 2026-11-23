"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import {
  assignRole,
  createUser,
  issueTemporaryPassword,
  removeRole,
  setPdvPin,
  setUserBranches,
  updateUser,
  UserFormState,
} from "./actions";
import styles from "../terminais/page.module.css";

export interface UserRow {
  id: string;
  code: string;
  name: string;
  email: string | null;
  is_active: boolean;
  has_access: boolean;
  branch_ids: string[];
  roles: { id: string; role_id: string; name: string; branch_id: string | null }[];
}

export interface RoleOption {
  id: string;
  name: string;
  system_key: string | null;
}

export interface BranchOption {
  id: string;
  name: string;
}

export function CreateUserForm() {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    createUser,
    {},
  );
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) form.current?.reset();
  }, [state]);

  return (
    <section className={styles.card}>
      <h2>Novo usuário</h2>
      <p className={styles.hint}>
        O e-mail só é necessário para quem usa a retaguarda. Operadores de caixa
        podem ficar sem.
      </p>
      <form ref={form} action={action} className={styles.inline}>
        <label>
          Nome
          <input name="name" required maxLength={200} />
        </label>
        <label>
          E-mail
          <input name="email" type="email" maxLength={254} autoComplete="off" />
        </label>
        <button type="submit" disabled={pending}>
          Criar usuário
        </button>
      </form>
      <ErrorNotice error={state.error} />
      {state.done && (
        <p className={styles.success} role="status">
          Usuário criado.
        </p>
      )}
    </section>
  );
}

export function EditUser({ user }: { user: UserRow }) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    updateUser,
    {},
  );
  return (
    <details className={styles.reason}>
      <summary>Editar</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={user.id} />
        <label>
          Nome
          <input name="name" required maxLength={200} defaultValue={user.name} />
        </label>
        <label>
          E-mail
          <input
            name="email"
            type="email"
            maxLength={254}
            defaultValue={user.email ?? ""}
            autoComplete="off"
          />
        </label>
        <label className={styles.check}>
          <input
            name="isActive"
            type="checkbox"
            defaultChecked={user.is_active}
          />
          Ativo
        </label>
        <button type="submit" disabled={pending}>
          Salvar
        </button>
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Alterações salvas.
          </p>
        )}
      </form>
    </details>
  );
}

export function UserBranches({
  user,
  branches,
}: {
  user: UserRow;
  branches: BranchOption[];
}) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    setUserBranches,
    {},
  );
  return (
    <details className={styles.reason}>
      <summary>Filiais</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={user.id} />
        {branches.map((branch) => (
          <label key={branch.id} className={styles.check}>
            <input
              name="branchIds"
              type="checkbox"
              value={branch.id}
              defaultChecked={user.branch_ids.includes(branch.id)}
            />
            {branch.name}
          </label>
        ))}
        <button type="submit" disabled={pending}>
          Salvar filiais
        </button>
        <ErrorNotice error={state.error} />
        {state.done && (
          <p className={styles.success} role="status">
            Filiais salvas.
          </p>
        )}
      </form>
    </details>
  );
}

function RemoveRoleButton({ userRoleId }: { userRoleId: string }) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    removeRole,
    {},
  );
  return (
    <form action={action}>
      <input type="hidden" name="userRoleId" value={userRoleId} />
      <button type="submit" disabled={pending}>
        Retirar
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}

export function UserRoles({
  user,
  roles,
  branches,
  branchName,
}: {
  user: UserRow;
  roles: RoleOption[];
  branches: BranchOption[];
  branchName: Record<string, string>;
}) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    assignRole,
    {},
  );
  const linked = branches.filter((branch) => user.branch_ids.includes(branch.id));
  return (
    <details className={styles.reason}>
      <summary>Perfis</summary>
      <div className={styles.rowForm}>
        {user.roles.map((role) => (
          <div key={role.id} className={styles.inline}>
            <span>
              {role.name}
              {" · "}
              {role.branch_id ? (branchName[role.branch_id] ?? "Filial") : "Todas as filiais"}
            </span>
            <RemoveRoleButton userRoleId={role.id} />
          </div>
        ))}
        <form action={action} className={styles.rowForm}>
          <input type="hidden" name="id" value={user.id} />
          <label>
            Perfil
            <select name="roleId" required defaultValue="">
              <option value="" disabled>
                Selecione
              </option>
              {roles.map((role) => (
                <option key={role.id} value={role.id}>
                  {role.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Onde vale
            <select name="branchId" defaultValue="">
              <option value="">Todas as filiais do usuário</option>
              {linked.map((branch) => (
                <option key={branch.id} value={branch.id}>
                  {branch.name}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" disabled={pending}>
            Atribuir perfil
          </button>
          <ErrorNotice error={state.error} />
          {state.done && (
            <p className={styles.success} role="status">
              Perfil atribuído.
            </p>
          )}
        </form>
      </div>
    </details>
  );
}

/** PIN para entrar no PDV, inclusive sem internet. Quem define é quem pode gerar senha temporária. */
export function PdvPin({ user }: { user: UserRow }) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(setPdvPin, {});
  const formRef = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.done) formRef.current?.reset();
  }, [state]);
  return (
    <details className={styles.reason}>
      <summary>PIN do PDV</summary>
      <form ref={formRef} action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={user.id} />
        <p className={styles.hint}>
          De 4 a 6 números, sem repetir o mesmo número e sem sequência. Entra no PDV com o código {user.code} e este
          PIN, mesmo sem internet. Um PIN novo substitui o anterior.
        </p>
        <label>
          PIN
          <input name="pin" type="password" inputMode="numeric" pattern="[0-9]{4,6}" required autoComplete="new-password" />
        </label>
        <label>
          Repita o PIN
          <input name="confirmation" type="password" inputMode="numeric" pattern="[0-9]{4,6}" required autoComplete="new-password" />
        </label>
        <button type="submit" disabled={pending}>
          Salvar PIN
        </button>
        <ErrorNotice error={state.error} />
        {state.done && <p role="status">PIN salvo. Ele chega aos PDVs da filial na próxima sincronização.</p>}
      </form>
    </details>
  );
}

export function TemporaryPassword({ user }: { user: UserRow }) {
  const [state, action, pending] = useActionState<UserFormState, FormData>(
    issueTemporaryPassword,
    {},
  );
  return (
    <details className={styles.reason}>
      <summary>{user.has_access ? "Nova senha" : "Liberar acesso"}</summary>
      <form action={action} className={styles.rowForm}>
        <input type="hidden" name="id" value={user.id} />
        <p className={styles.warning}>
          Isso encerra as sessões do usuário, que deverá trocar a senha ao entrar.
        </p>
        <button type="submit" disabled={pending}>
          Gerar senha temporária
        </button>
        <ErrorNotice error={state.error} />
        {state.temporaryPassword && (
          <div role="status">
            <p>Passe esta senha ao usuário. Ela não aparece de novo:</p>
            <code className={styles.secret}>{state.temporaryPassword}</code>
          </div>
        )}
      </form>
    </details>
  );
}
