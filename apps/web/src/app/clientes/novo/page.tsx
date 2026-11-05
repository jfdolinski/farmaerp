import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { can, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { CreateCustomerForm } from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Novo cliente · FarmaERP" };

export default function NewCustomerPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando...</p>}>
        <NewCustomerContent />
      </Suspense>
    </main>
  );
}

async function NewCustomerContent() {
  const user = await requireUser("/clientes/novo");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Novo cliente</h1>
        <Link href="/clientes">Voltar para clientes</Link>
      </div>
      <section className={styles.card}>
        {can(user, "customers.manage") ? (
          <CreateCustomerForm />
        ) : (
          <p>Você não tem permissão para cadastrar clientes.</p>
        )}
      </section>
    </>
  );
}
