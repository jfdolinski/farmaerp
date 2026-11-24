import Link from "next/link";
import { can, CurrentUser } from "@/lib/api";
import { logout } from "./auth-actions";
import styles from "./terminais/page.module.css";

export function AppHeader({ user }: { user: CurrentUser }) {
  return (
    <header className={styles.appHeader}>
      <nav className={styles.nav} aria-label="Principal">
        <strong>FarmaERP</strong>
        {(can(user, "products.view") || can(user, "products.manage")) && (
          <Link href="/produtos">Produtos</Link>
        )}
        {can(user, "stock.view") && <Link href="/estoque">Estoque</Link>}
        {(can(user, "customers.view") || can(user, "customers.manage")) && (
          <Link href="/clientes">Clientes</Link>
        )}
        {(can(user, "purchases.view") || can(user, "purchases.manage")) && (
          <Link href="/notas">Notas</Link>
        )}
        {(can(user, "purchases.view") || can(user, "purchases.manage")) && (
          <Link href="/notas-servico">Notas de serviço</Link>
        )}
        {(can(user, "purchases.view") || can(user, "purchases.manage")) && (
          <Link href="/fornecedores">Fornecedores</Link>
        )}
        {(can(user, "fiscal.view") || can(user, "fiscal.manage") || can(user, "fiscal.certificate")) && (
          <Link href="/fiscal">Fiscal</Link>
        )}
        {(can(user, "rules.view") || can(user, "rules.manage")) && (
          <Link href="/regras">Regras</Link>
        )}
        {(can(user, "structure.manage") || can(user, "branches.view_all")) && (
          <Link href="/empresas">Empresas</Link>
        )}
        {(can(user, "terminals.view") || can(user, "terminals.request")) && (
          <Link href="/terminais">Terminais</Link>
        )}
        {(can(user, "users.view") || can(user, "users.manage")) && (
          <Link href="/usuarios">Usuários</Link>
        )}
        {(can(user, "roles.manage") || can(user, "roles.assign")) && (
          <Link href="/perfis">Perfis</Link>
        )}
        {can(user, "releases.view") && <Link href="/liberacoes">Liberações</Link>}
        {can(user, "sales.view") && <Link href="/vendas">Vendas</Link>}
        {can(user, "sales.view") && <Link href="/caixas">Caixas</Link>}
        {can(user, "sales.view") && <Link href="/orcamentos">Orçamentos</Link>}
        {can(user, "controlled.view") && <Link href="/controlados">Controlados</Link>}
        {can(user, "sync.view") && <Link href="/sincronizacao">Sincronização</Link>}
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
