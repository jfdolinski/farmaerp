"use client";

import Link from "next/link";
import { useLayoutEffect, useRef, useState } from "react";
import styles from "./shell.module.css";

export interface TabItem {
  id: string;
  label: string;
  /** Número ao lado do nome, como a quantidade de itens. */
  count?: number;
  /** Destaca a aba quando há algo para resolver nela. */
  attention?: boolean;
}

/**
 * Barra de abas. A aba é um link (?aba=), então recarregar ou abrir em outra janela mantém a
 * aba; o indicador desliza até a aba clicada antes mesmo da tela chegar.
 */
export function TabBar({ items, active, hrefs }: { items: TabItem[]; active: string; hrefs: string[] }) {
  const bar = useRef<HTMLDivElement>(null);
  const [pending, setPending] = useState<{ from: string; to: string } | null>(null);
  const [indicator, setIndicator] = useState<{ left: number; width: number } | null>(null);
  const shown = pending && pending.from === active ? pending.to : active;

  useLayoutEffect(() => {
    const element = bar.current?.querySelector<HTMLElement>(`[data-tab="${CSS.escape(shown)}"]`);
    if (!element) return;
    setIndicator({ left: element.offsetLeft, width: element.offsetWidth });
    element.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [shown]);

  return (
    <div className={styles.tabBar} ref={bar}>
      <nav aria-label="Seções desta tela" className={styles.tabList}>
        {items.map((item, index) => (
          <Link
            key={item.id}
            href={hrefs[index]}
            scroll={false}
            replace
            data-tab={item.id}
            className={styles.tab}
            aria-current={item.id === shown ? "page" : undefined}
            data-attention={item.attention || undefined}
            onClick={() => setPending({ from: active, to: item.id })}
          >
            {item.label}
            {item.count !== undefined && <span className={styles.tabCount}>{item.count}</span>}
          </Link>
        ))}
      </nav>
      {indicator && (
        <span
          className={styles.tabIndicator}
          aria-hidden="true"
          style={{ transform: `translateX(${indicator.left}px)`, width: indicator.width }}
        />
      )}
    </div>
  );
}
