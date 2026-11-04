import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, CurrentUser, redirectIfNeeded } from "@/lib/api";
import { logout } from "../auth-actions";
import { ChangePasswordForm } from "./form";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Trocar senha · FarmaERP" };

export default function ChangePasswordPage() {
  return (
    <main className={styles.centered}>
      <section className={styles.card}>
        <h1>Trocar senha</h1>
        <Suspense fallback={<p className={styles.hint}>Carregando...</p>}>
          <ChangePasswordContent />
        </Suspense>
      </section>
    </main>
  );
}

async function ChangePasswordContent() {
  const me = await apiFetch<CurrentUser>("/auth/me");
  if (!me.ok) {
    redirectIfNeeded(me.error, "/trocar-senha");
    throw new Error(me.error.message);
  }
  return (
    <>
      <p className={styles.hint}>
        {me.data.mustChangePassword
          ? "Para continuar, defina uma senha só sua."
          : `Trocando a senha de ${me.data.name}.`}{" "}
        Use ao menos 10 caracteres. Uma frase é mais fácil de lembrar.
      </p>
      <ChangePasswordForm />
      <form action={logout}>
        <button type="submit">Sair</button>
      </form>
    </>
  );
}
