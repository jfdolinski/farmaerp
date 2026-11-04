import Link from "next/link";
import type { CurrentUser } from "@/lib/api";
import { logout } from "./auth-actions";
import styles from "./terminais/page.module.css";

export function AppHeader({ user }: { user: CurrentUser }) {
  return (
    <header className={styles.appHeader}>
      <nav className={styles.nav} aria-label="Principal">
        <strong>FarmaERP</strong>
        <Link href="/terminais">Terminais</Link>
        <Link href="/usuarios">Usuários</Link>
      </nav>
      <div className={styles.nav}>
        <span>{user.name}</span>
        <form action={logout}>
          <button type="submit">Sair</button>
        </form>
      </div>
    </header>
  );
}
