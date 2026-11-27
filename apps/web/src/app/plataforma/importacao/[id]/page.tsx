import type { Metadata } from "next";
import { Suspense } from "react";
import { ReportContent } from "../../../importacoes/report";
import styles from "../../../terminais/page.module.css";

export const metadata: Metadata = { title: "Relatório da importação · FarmaERP" };

/** Relatório de um arquivo que a Plataforma enviou para um cliente: o mesmo da importação do cliente. */
export default function PlatformImportReportPage({ params }: { params: Promise<{ id: string }> }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando relatório...</p>}>
        <ReportContent params={params} platform />
      </Suspense>
    </main>
  );
}
