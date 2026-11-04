import type { ApiError } from "@/lib/api";
import styles from "./terminais/page.module.css";

export function formatReference(code: string, traceId: string | null): string {
  return traceId ? `Código ${code} · Ref. ${traceId.slice(-8)}` : `Código ${code}`;
}

export function ErrorNotice({ error }: { error?: ApiError }) {
  if (!error) return null;
  return (
    <div className={styles.error} role="alert">
      <strong>{error.message}</strong>
      <span>{error.action}</span>
      <small>{formatReference(error.code, error.traceId)}</small>
    </div>
  );
}
