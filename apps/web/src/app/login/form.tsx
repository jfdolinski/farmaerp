"use client";

import { useActionState } from "react";
import { AuthFormState, login } from "../auth-actions";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";

export function LoginForm({
  next,
  expired,
}: {
  next?: string;
  expired: boolean;
}) {
  const [state, action, pending] = useActionState<AuthFormState, FormData>(
    login,
    {},
  );
  return (
    <form action={action} className={styles.stack}>
      {expired && !state.error && (
        <p className={styles.warning} role="status">
          Sua sessão expirou. Entre novamente para continuar.
        </p>
      )}
      <input type="hidden" name="next" value={next ?? ""} />
      <label>
        E-mail
        <input
          name="email"
          type="email"
          required
          autoComplete="username"
          autoFocus
        />
      </label>
      <label>
        Senha
        <input
          name="password"
          type="password"
          required
          autoComplete="current-password"
        />
      </label>
      <button type="submit" disabled={pending}>
        {pending ? "Entrando..." : "Entrar"}
      </button>
      <ErrorNotice error={state.error} />
      <p className={styles.hint}>
        Esqueceu a senha? Peça uma senha temporária ao administrador.
      </p>
    </form>
  );
}
