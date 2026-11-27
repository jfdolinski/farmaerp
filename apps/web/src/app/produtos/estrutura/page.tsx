import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { AddEntryForm, CategoryRow, EntryRow, GroupRow, ProductStructure } from "../ui";
import styles from "../../terminais/page.module.css";
import { activeTab, TabItem, Tabs } from "../../shell/tabs";

export const metadata: Metadata = { title: "Estrutura de produtos · FarmaERP" };

type SearchParams = Promise<{ aba?: string | string[] }>;

const GROUP_KINDS: { kind: GroupRow["kind"]; tab: string; label: string; title: string; add: string }[] = [
  {
    kind: "commission",
    tab: "comissao",
    label: "Comissão",
    title: "Grupos de comissão",
    add: "Novo grupo de comissão",
  },
  {
    kind: "pricing",
    tab: "precificacao",
    label: "Precificação",
    title: "Grupos de precificação",
    add: "Novo grupo de precificação",
  },
  {
    kind: "price_family",
    tab: "familias",
    label: "Famílias de preço",
    title: "Grupos de preço (famílias)",
    add: "Nova família",
  },
];

export default function StructurePage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando estrutura...</p>}>
        <StructureContent searchParams={searchParams} />
      </Suspense>
    </main>
  );
}

function CategoryBranch({
  category,
  categories,
  canManage,
}: {
  category: CategoryRow;
  categories: CategoryRow[];
  canManage: boolean;
}) {
  const children = categories.filter((item) => item.parent_id === category.id);
  return (
    <div className={styles.device}>
      <EntryRow entity="category" id={category.id} name={category.name} canManage={canManage} />
      {children.map((child) => (
        <CategoryBranch key={child.id} category={child} categories={categories} canManage={canManage} />
      ))}
      {canManage && category.level < 3 && (
        <AddEntryForm
          entity="category"
          parentId={category.id}
          label={category.level === 1 ? "Nova categoria" : "Nova subcategoria"}
        />
      )}
    </div>
  );
}

async function StructureContent({ searchParams }: { searchParams: SearchParams }) {
  const user = await requireUser("/produtos/estrutura");
  const canManage = can(user, "products.manage");

  if (!can(user, "products.view") && !canManage) {
    return (
      <>
        <AppHeader user={user} />
        <h1>Estrutura de produtos</h1>
        <section className={styles.card}>
          <p>Você não tem permissão para ver os produtos.</p>
        </section>
      </>
    );
  }

  const result = await apiFetch<ProductStructure>("/admin/product-structure");
  if (!result.ok) {
    redirectIfNeeded(result.error, "/produtos/estrutura");
    return (
      <>
        <AppHeader user={user} />
        <div className={styles.header}>
          <h1>Estrutura de produtos</h1>
          <Link href="/produtos">Voltar para produtos</Link>
        </div>
        <ErrorNotice error={result.error} />
      </>
    );
  }
  const structure = result.data;
  const tabs: TabItem[] = [
    { id: "categorias", label: "Categorias" },
    ...GROUP_KINDS.map(({ tab, kind, label }) => ({
      id: tab,
      label,
      count: structure.groups.filter((group) => group.kind === kind).length,
    })),
    { id: "canais", label: "Canais de venda", count: structure.channels.length },
  ];
  const tab = activeTab(tabs, (await searchParams).aba);

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Estrutura de produtos</h1>
        <Link href="/produtos">Voltar para produtos</Link>
      </div>
      <Tabs base="/produtos/estrutura" items={tabs} active={tab}>
        {tab === "categorias" && (
          <section className={styles.card}>
            <h2>Departamentos, categorias e subcategorias</h2>
            {structure.categories
              .filter((category) => category.level === 1)
              .map((department) => (
                <CategoryBranch
                  key={department.id}
                  category={department}
                  categories={structure.categories}
                  canManage={canManage}
                />
              ))}
            {canManage && <AddEntryForm entity="category" label="Novo departamento" />}
          </section>
        )}
        {GROUP_KINDS.filter((item) => item.tab === tab).map(({ kind, title, add }) => (
          <section key={kind} className={styles.card}>
            <h2>{title}</h2>
            {structure.groups
              .filter((group) => group.kind === kind)
              .map((group) => (
                <EntryRow key={group.id} entity="group" id={group.id} name={group.name} canManage={canManage} />
              ))}
            {canManage && <AddEntryForm entity="group" kind={kind} label={add} />}
          </section>
        ))}
        {tab === "canais" && (
          <section className={styles.card}>
            <h2>Canais de venda</h2>
            {structure.channels.map((channel) => (
              <EntryRow key={channel.id} entity="channel" id={channel.id} name={channel.name} canManage={canManage} />
            ))}
            {canManage && <AddEntryForm entity="channel" label="Novo canal" />}
          </section>
        )}
      </Tabs>
    </>
  );
}
