import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { ReleaseActions } from "./ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Versões do PDV · FarmaERP" };

interface ReleaseRow {
  id: string;
  app: string;
  platform: string;
  app_version: string;
  size_bytes: string;
  sha256: string;
  notes: string | null;
  status: "test" | "general" | "withdrawn";
  created_at: string;
  released_at: string | null;
  withdrawn_at: string | null;
  terminals_on: number;
  applied: number;
  rolled_back: number;
}

const STATUS: Record<string, string> = {
  test: "Só terminais de teste",
  general: "Liberada para a rede",
  withdrawn: "Retirada",
};
const PLATFORM: Record<string, string> = { windows: "Windows", linux: "Linux" };
const dateText = (value: string | null) =>
  value ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" }) : "";
const sizeText = (bytes: string) => `${(Number(bytes) / 1024 / 1024).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} MB`;

export default function ReleasesPage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando as versões...</p>}>
        <ReleasesContent />
      </Suspense>
    </main>
  );
}

async function ReleasesContent() {
  const user = await requireUser("/plataforma/versoes");
  if (!user.platformAdmin) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Versões do PDV</h1>
        <section className={styles.card}>
          <p>Esta área é só do administrador da plataforma.</p>
        </section>
      </>
    );
  }
  const result = await apiFetch<ReleaseRow[]>("/platform/releases");
  if (!result.ok) redirectIfNeeded(result.error, "/plataforma/versoes");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Versões do PDV</h1>
        <Link href="/plataforma">Voltar para a plataforma</Link>
      </div>
      <section className={styles.card}>
        <p className={styles.hint}>
          Cada versão chega pelo CI, assinada, e vai primeiro só para os terminais marcados como teste (em Terminais, por
          cliente). Depois de conferida, libere para a rede. Os PDVs baixam sozinhos e aplicam depois do fechamento de
          caixa ou na próxima abertura; se a versão nova falhar, o PDV volta à anterior e aparece aqui em &quot;voltaram&quot;.
        </p>
        {!result.ok && <ErrorNotice error={result.error} />}
        {result.ok && result.data.length === 0 && <p className={styles.hint}>Nenhuma versão publicada.</p>}
        {result.ok && result.data.length > 0 && (
          <div className={styles.tableWrap}>
            <table>
              <thead>
                <tr>
                  <th>Versão</th>
                  <th>Situação</th>
                  <th>Terminais</th>
                  <th>Arquivo</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {result.data.map((release) => (
                  <tr key={release.id}>
                    <td>
                      {release.app_version}
                      <small>
                        {release.app.toUpperCase()} · {PLATFORM[release.platform] ?? release.platform}
                      </small>
                      {release.notes && <small>{release.notes}</small>}
                    </td>
                    <td>
                      {STATUS[release.status]}
                      <small>Publicada em {dateText(release.created_at)}</small>
                      {release.released_at && <small>Liberada em {dateText(release.released_at)}</small>}
                      {release.withdrawn_at && <small>Retirada em {dateText(release.withdrawn_at)}</small>}
                    </td>
                    <td>
                      {release.terminals_on} nesta versão
                      <small>{release.applied} aplicaram</small>
                      {release.rolled_back > 0 && (
                        <small className={styles.warning}>{release.rolled_back} voltaram à versão anterior</small>
                      )}
                    </td>
                    <td>
                      {sizeText(release.size_bytes)}
                      <small title={release.sha256}>SHA-256 {release.sha256.slice(0, 12)}…</small>
                    </td>
                    <td>
                      {release.status !== "withdrawn" && (
                        <ReleaseActions id={release.id} status={release.status} version={release.app_version} />
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </>
  );
}
