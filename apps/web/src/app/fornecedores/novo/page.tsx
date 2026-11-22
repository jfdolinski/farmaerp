import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { can, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import styles from "../../terminais/page.module.css";
import { CreateSupplierForm } from "../ui";

export const metadata: Metadata = { title: "Novo fornecedor · FarmaERP" };

export default function NewSupplierPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando...</p>}>
        <NewSupplierContent />
      </Suspense>
    </main>
  );
}

async function NewSupplierContent() {
  const user = await requireUser("/fornecedores/novo");
  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Novo fornecedor</h1>
        <Link href="/fornecedores">Voltar para fornecedores</Link>
      </div>
      <section className={styles.card}>
        {can(user, "purchases.manage") ? (
          <CreateSupplierForm />
        ) : (
          <p>Você não tem permissão para cadastrar fornecedores.</p>
        )}
      </section>
    </>
  );
}
