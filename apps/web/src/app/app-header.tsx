import { can, CurrentUser } from "@/lib/api";
import { logout } from "./auth-actions";
import { NavGroup, Sidebar } from "./shell/sidebar";
import shell from "./shell/shell.module.css";

/** Menu da retaguarda. Cada link continua liberado pela permissão do perfil, como antes. */
function menu(user: CurrentUser): NavGroup[] {
  const any = (...codes: string[]) => codes.some((code) => can(user, code));
  const purchases = any("purchases.view", "purchases.manage");
  const sales = can(user, "sales.view");
  const rules = any("rules.view", "rules.manage");

  const groups: NavGroup[] = [
    {
      label: "Vendas",
      links: [
        sales && { href: "/vendas", label: "Vendas" },
        sales && { href: "/caixas", label: "Caixas" },
        sales && { href: "/orcamentos", label: "Orçamentos" },
        sales && { href: "/devolucoes", label: "Devoluções" },
        sales && { href: "/vendas-importadas", label: "Vendas importadas" },
      ],
    },
    {
      label: "Produtos e estoque",
      links: [
        any("products.view", "products.manage") && { href: "/produtos", label: "Produtos" },
        can(user, "stock.view") && { href: "/estoque", label: "Estoque" },
        can(user, "stock.opening") && { href: "/inventario", label: "Inventário" },
        can(user, "controlled.view") && { href: "/controlados", label: "Controlados" },
      ],
    },
    {
      label: "Compras",
      links: [
        purchases && { href: "/notas", label: "Notas de entrada" },
        any("stock.view", "purchases.view") && { href: "/notas-importadas", label: "Notas importadas" },
        purchases && { href: "/notas-servico", label: "Notas de serviço" },
        purchases && { href: "/fornecedores", label: "Fornecedores" },
        can(user, "imports.manage") && { href: "/importacoes", label: "Importação de notas" },
      ],
    },
    {
      label: "Clientes",
      links: [
        any("customers.view", "customers.manage") && { href: "/clientes", label: "Clientes" },
        can(user, "credit.view") && { href: "/crediario", label: "Crediário" },
        rules && { href: "/descontos", label: "Descontos" },
        any("health_professionals.manage", "controlled.view") && {
          href: "/profissionais",
          label: "Profissionais da saúde",
        },
      ],
    },
    {
      label: "Fiscal",
      links: [
        any("fiscal.view", "fiscal.manage", "fiscal.certificate") && { href: "/fiscal", label: "Fiscal" },
        sales && { href: "/notas-fiscais", label: "Notas fiscais" },
        can(user, "sngpc.manage") && { href: "/sngpc", label: "SNGPC" },
        rules && { href: "/regras", label: "Regras" },
      ],
    },
    {
      label: "Administração",
      links: [
        any("structure.manage", "branches.view_all") && { href: "/empresas", label: "Empresas" },
        any("terminals.view", "terminals.request") && { href: "/terminais", label: "Terminais" },
        any("users.view", "users.manage") && { href: "/usuarios", label: "Usuários" },
        any("roles.manage", "roles.assign") && { href: "/perfis", label: "Perfis" },
        can(user, "releases.view") && { href: "/liberacoes", label: "Liberações" },
        can(user, "sync.view") && { href: "/sincronizacao", label: "Sincronização" },
        can(user, "users.view") && { href: "/entradas-pdv", label: "Entradas no PDV" },
        user.platformAdmin && { href: "/plataforma", label: "Plataforma" },
      ],
    },
  ].map((group) => ({ label: group.label, links: group.links.filter((link) => !!link) as NavGroup["links"] }));

  return groups.filter((group) => group.links.length > 0);
}

/**
 * Moldura das telas: menu lateral agrupado e barra de cima com o usuário. O nome ficou AppHeader
 * porque todas as telas já o chamam no começo do conteúdo.
 */
export function AppHeader({ user }: { user: CurrentUser }) {
  return (
    <>
      <Sidebar groups={menu(user)} />
      <header className={shell.topbar} data-shell="">
        <span className={shell.userName}>{user.name}</span>
        <form action={logout}>
          <button type="submit" className={shell.logout}>
            Sair
          </button>
        </form>
      </header>
    </>
  );
}
