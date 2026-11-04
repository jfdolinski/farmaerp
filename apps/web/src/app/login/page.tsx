import type { Metadata } from "next";
import { Suspense } from "react";
import { LoginForm } from "./form";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Entrar · FarmaERP" };

export default function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; expired?: string }>;
}) {
  return (
    <main className={styles.centered}>
      <section className={styles.card}>
        <h1>FarmaERP</h1>
        <p className={styles.hint}>Entre com seu e-mail e sua senha.</p>
        <Suspense fallback={null}>
          <LoginContent searchParams={searchParams} />
        </Suspense>
      </section>
    </main>
  );
}

async function LoginContent({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; expired?: string }>;
}) {
  const { next, expired } = await searchParams;
  return <LoginForm next={next} expired={expired === "1"} />;
}
