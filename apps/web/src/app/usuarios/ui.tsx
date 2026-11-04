"use client";

import { useActionState, useEffect, useRef } from "react";
import { ErrorNotice } from "../error-notice";
import {
  createUser,
  issueTemporaryPassword,
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
  is_group_admin: boolean;
  is_active: boolean;
  has_access: boolean;
  branch_ids: string[];
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
        <label className={styles.check}>
          <input name="isGroupAdmin" type="checkbox" />
          Administrador
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
            name="isGroupAdmin"
            type="checkbox"
            defaultChecked={user.is_group_admin}
          />
          Administrador
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
        {user.is_group_admin && (
          <p className={styles.hint}>
            Administradores já enxergam todas as filiais do grupo.
          </p>
        )}
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
