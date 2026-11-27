"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useLayoutEffect, useRef, useState } from "react";
import styles from "./shell.module.css";

export interface NavLink {
  href: string;
  label: string;
}

export interface NavGroup {
  label: string;
  links: NavLink[];
}

const isActive = (pathname: string, href: string) => pathname === href || pathname.startsWith(`${href}/`);

/*
 * Cada tela monta o menu de novo. O que a pessoa abriu ou fechou, e até onde rolou o menu, fica guardado
 * aqui enquanto a aba do navegador estiver aberta.
 */
const remembered: { groups: Record<string, boolean>; scroll: number } = { groups: {}, scroll: 0 };

function remember(update: Partial<typeof remembered>) {
  Object.assign(remembered, update);
}

/** Menu lateral agrupado. Em tela estreita vira gaveta aberta pelo botão Menu. */
export function Sidebar({ groups }: { groups: NavGroup[] }) {
  const pathname = usePathname();
  const current = groups.find((group) => group.links.some((link) => isActive(pathname, link.href)))?.label;
  const [choices, setChoices] = useState<Record<string, boolean>>(() => ({ ...remembered.groups }));
  const [drawer, setDrawer] = useState(false);
  const nav = useRef<HTMLElement>(null);

  useLayoutEffect(() => {
    if (nav.current) nav.current.scrollTop = remembered.scroll;
  }, []);

  const isOpen = (label: string) => choices[label] ?? label === current;
  const toggle = (label: string) => {
    const next = { ...choices, [label]: !isOpen(label) };
    remember({ groups: next });
    setChoices(next);
  };

  return (
    <>
      <button
        type="button"
        className={styles.menuButton}
        aria-expanded={drawer}
        aria-controls="menu-principal"
        onClick={() => setDrawer((value) => !value)}
      >
        Menu
      </button>
      {drawer && <div className={styles.scrim} onClick={() => setDrawer(false)} aria-hidden="true" />}
      <aside id="menu-principal" className={styles.sidebar} data-open={drawer} data-shell="">
        <Link href="/terminais" className={styles.brand}>
          <span className={styles.brandMark} aria-hidden="true" />
          FarmaERP
        </Link>
        <nav
          aria-label="Principal"
          className={styles.groups}
          ref={nav}
          onScroll={(event) => remember({ scroll: event.currentTarget.scrollTop })}
        >
          {groups.map((group) => {
            const expanded = isOpen(group.label);
            const id = `menu-${group.label.toLowerCase().replace(/\W+/g, "-")}`;
            return (
              <div key={group.label} className={styles.group}>
                <button
                  type="button"
                  className={styles.groupButton}
                  aria-expanded={expanded}
                  aria-controls={id}
                  data-current={group.label === current}
                  onClick={() => toggle(group.label)}
                >
                  {group.label}
                  <span className={styles.chevron} aria-hidden="true" />
                </button>
                <div id={id} className={styles.groupBody} data-expanded={expanded}>
                  <ul>
                    {group.links.map((link) => {
                      const active = isActive(pathname, link.href);
                      return (
                        <li key={link.href}>
                          <Link
                            href={link.href}
                            className={styles.link}
                            aria-current={active ? "page" : undefined}
                            tabIndex={expanded ? undefined : -1}
                            onClick={() => setDrawer(false)}
                          >
                            {link.label}
                          </Link>
                        </li>
                      );
                    })}
                  </ul>
                </div>
              </div>
            );
          })}
        </nav>
      </aside>
    </>
  );
}
