import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import { AgreementForm, AgreementRow } from "../clientes/ui";
import styles from "../terminais/page.module.css";

export const metadata: Metadata = { title: "Convênios · FarmaERP" };

export default function AgreementsPage() {
  return (
    <main className={styles.page}>
      <Suspense
        fallback={<p className={styles.hint}>Carregando convênios...</p>}
      >
        <AgreementsContent />
      </Suspense>
    </main>
  );
}

async function AgreementsContent() {
  const user = await requireUser("/convenios");

  if (!can(user, "agreements.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Convênios</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para cadastrar convênios.</p>
        </section>
      </>
    );
  }

  const agreements = await apiFetch<AgreementRow[]>("/admin/agreements");
  if (!agreements.ok) redirectIfNeeded(agreements.error, "/convenios");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Convênios</h1>
        <Link href="/clientes">Voltar para clientes</Link>
      </div>
      <section className={styles.card}>
        <h2>Novo convênio</h2>
        <AgreementForm />
      </section>
      <section className={styles.card}>
        <h2>Convênios</h2>
        {!agreements.ok && <ErrorNotice error={agreements.error} />}
        {agreements.ok && agreements.data.length === 0 && (
          <p className={styles.hint}>Nenhum convênio ainda.</p>
        )}
        {agreements.ok &&
          agreements.data.map((agreement) => (
            <AgreementForm key={agreement.id} agreement={agreement} />
          ))}
        <p className={styles.hint}>
          Matrícula e limite de cada cliente ficam na ficha dele. As regras de
          desconto do convênio chegam com a venda.
        </p>
      </section>
    </>
  );
}
