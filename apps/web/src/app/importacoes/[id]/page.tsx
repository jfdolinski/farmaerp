import type { Metadata } from "next";
import { Suspense } from "react";
import styles from "../../terminais/page.module.css";
import { type Params, ReportContent } from "../report";

export const metadata: Metadata = { title: "Relatório da importação · FarmaERP" };

export default function ImportReportPage({ params }: { params: Params }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando relatório...</p>}>
        <ReportContent params={params} />
      </Suspense>
    </main>
  );
}
