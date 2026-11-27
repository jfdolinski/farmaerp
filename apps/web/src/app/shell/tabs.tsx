import type { ReactNode } from "react";
import { TabBar, TabItem } from "./tab-bar";
import styles from "./shell.module.css";

export type { TabItem };

/** Aba pedida no endereço (?aba=), ou a primeira quando não vier ou não existir. */
export function activeTab(items: TabItem[], requested: string | string[] | undefined): string {
  const value = typeof requested === "string" ? requested : "";
  return items.some((item) => item.id === value) ? value : items[0].id;
}

/**
 * Tela em abas: só a aba aberta é montada no servidor, e só o painel rola, não a página.
 * `base` é o endereço da tela; `keep` são parâmetros do endereço que valem para todas as abas.
 */
export function Tabs({
  base,
  items,
  active,
  keep = {},
  children,
}: {
  base: string;
  items: TabItem[];
  active: string;
  keep?: Record<string, string>;
  children: ReactNode;
}) {
  const hrefs = items.map((item, index) => {
    const query = new URLSearchParams(keep);
    if (index > 0) query.set("aba", item.id);
    const text = query.toString();
    return text ? `${base}?${text}` : base;
  });
  return (
    <div className={styles.tabs} data-tabs="">
      <TabBar items={items} active={active} hrefs={hrefs} />
      <div key={active} className={styles.tabPanel}>
        {children}
      </div>
    </div>
  );
}
