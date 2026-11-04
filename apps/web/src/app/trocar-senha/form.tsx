"use client";

import { useActionState } from "react";
import { AuthFormState, changePassword } from "../auth-actions";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";

export function ChangePasswordForm() {
  const [state, action, pending] = useActionState<AuthFormState, FormData>(
    changePassword,
    {},
  );
  return (
    <form action={action} className={styles.stack}>
      <label>
        Senha atual
        <input
          name="currentPassword"
          type="password"
          required
          autoComplete="current-password"
        />
      </label>
      <label>
        Nova senha
        <input
          name="newPassword"
          type="password"
          required
          minLength={10}
          autoComplete="new-password"
        />
      </label>
      <button type="submit" disabled={pending}>
        {pending ? "Salvando..." : "Salvar nova senha"}
      </button>
      <ErrorNotice error={state.error} />
    </form>
  );
}
