import { connection } from "next/server";
import styles from "./environment-banner.module.css";

/** Evita confundir a homologação com a loja real. Lê o ambiente ao atender a requisição. */
export async function EnvironmentBanner() {
  await connection();
  if (process.env.APP_ENV !== "homologation") {
    return null;
  }
  return (
    <div className={styles.banner} role="status" data-env-banner="">
      HOMOLOGAÇÃO: ambiente de testes, sem dados reais
    </div>
  );
}
