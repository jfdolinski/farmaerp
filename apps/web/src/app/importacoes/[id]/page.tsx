import type { Metadata } from "next";
import { Suspense } from "react";
import styles from "../../terminais/page.module.css";
import { type Params, ReportContent, type SearchParams } from "../report";

export const metadata: Metadata = { title: "Relatório da importação · FarmaERP" };

export default function ImportReportPage({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando relatório...</p>}>
        <ReportContent params={params} searchParams={searchParams} />
      </Suspense>
    </main>
  );
}
