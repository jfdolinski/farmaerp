import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../app-header";
import { ErrorNotice } from "../error-notice";
import styles from "../terminais/page.module.css";
import { type ImportRow, RUNNING } from "./labels";
import { ImportList } from "./list";
import { AutoRefresh, ImportUploader } from "./ui";

export const metadata: Metadata = { title: "Importação de notas · FarmaERP" };

export default function ImportsPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando importações...</p>}>
        <ImportsContent />
      </Suspense>
    </main>
  );
}

async function ImportsContent() {
  const user = await requireUser("/importacoes");
  if (!can(user, "imports.manage")) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Importação de notas</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para importar notas.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ImportRow[]>("/admin/imports");
  if (!result.ok) redirectIfNeeded(result.error, "/importacoes");
  const rows = result.ok ? result.data : [];

  return (
    <>
      <AppHeader user={user} />
      {rows.some((row) => RUNNING.has(row.status)) && <AutoRefresh />}
      <h1>Importação de notas</h1>
      <p className={styles.hint}>
        Traga as notas do sistema anterior num arquivo .zip com os XML (pode ter pastas). Entram as NFC-e e as NF-e
        autorizadas, cada uma na data dela. NFC-e: a filial é cadastrada pelo CNPJ do emitente, os produtos pelo código
        do sistema anterior e os clientes pelo CPF ou CNPJ; cada venda baixa o estoque. NF-e: a compra recebida entra no
        estoque com o custo e o fornecedor; a venda vira venda importada; transferência, devolução e outras saídas
        movimentam o estoque das filiais. Notas canceladas desfazem o que fizeram. Enviar o mesmo arquivo de novo é
        seguro: notas repetidas são ignoradas.
      </p>
      <section className={styles.card}>
        <h2>Enviar arquivo</h2>
        <ImportUploader />
      </section>
      <section className={styles.card}>
        <h2>Arquivos enviados</h2>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && rows.length === 0 && <p className={styles.hint}>Nenhum arquivo enviado ainda.</p>}
        {rows.length > 0 && <ImportList rows={rows} base="/importacoes" />}
      </section>
    </>
  );
}
