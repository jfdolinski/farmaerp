import type { Metadata } from "next";
import { Suspense } from "react";
import styles from "../../../terminais/page.module.css";
import { type Params, ReportContent, type SearchParams } from "../../../importacoes/report";

export const metadata: Metadata = { title: "Relatório da importação · FarmaERP" };

/** Relatório de um arquivo que a Plataforma enviou para um cliente: o mesmo da importação do cliente. */
export default function PlatformImportReportPage({
  params,
  searchParams,
}: {
  params: Params;
  searchParams: SearchParams;
}) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando relatório...</p>}>
        <ReportContent params={params} searchParams={searchParams} platform />
      </Suspense>
    </main>
  );
}
