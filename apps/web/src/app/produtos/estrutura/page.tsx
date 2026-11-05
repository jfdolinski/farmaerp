import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { apiFetch, can, redirectIfNeeded, requireUser } from "@/lib/api";
import { AppHeader } from "../../app-header";
import { ErrorNotice } from "../../error-notice";
import { BranchLocationRow, BranchLocationValues } from "../commercial-ui";
import { AddEntryForm, CategoryRow, EntryRow, GroupRow, ProductStructure } from "../ui";
import styles from "../../terminais/page.module.css";

export const metadata: Metadata = { title: "Estrutura de produtos · FarmaERP" };

const GROUP_KINDS: { kind: GroupRow["kind"]; title: string; add: string }[] = [
  { kind: "commission", title: "Grupos de comissão", add: "Novo grupo de comissão" },
  { kind: "pricing", title: "Grupos de precificação", add: "Novo grupo de precificação" },
  { kind: "price_family", title: "Grupos de preço (famílias)", add: "Nova família" },
];

export default function StructurePage() {
  return (
    <main className={styles.page}>
      <Suspense fallback={<p className={styles.hint}>Carregando estrutura...</p>}>
        <StructureContent />
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

async function StructureContent() {
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

  const [result, branches] = await Promise.all([
    apiFetch<ProductStructure>("/admin/product-structure"),
    apiFetch<BranchLocationValues[]>("/admin/branches"),
  ]);
  if (!result.ok) redirectIfNeeded(result.error, "/produtos/estrutura");
  const canLocate = can(user, "structure.manage");

  return (
    <>
      <AppHeader user={user} />
      <div className={styles.header}>
        <h1>Estrutura de produtos</h1>
        <Link href="/produtos">Voltar para produtos</Link>
      </div>
      {!result.ok && <ErrorNotice error={result.error} />}
      {result.ok && (
        <>
          <section className={styles.card}>
            <h2>Departamentos, categorias e subcategorias</h2>
            {result.data.categories
              .filter((category) => category.level === 1)
              .map((department) => (
                <CategoryBranch
                  key={department.id}
                  category={department}
                  categories={result.data.categories}
                  canManage={canManage}
                />
              ))}
            {canManage && <AddEntryForm entity="category" label="Novo departamento" />}
          </section>
          {GROUP_KINDS.map(({ kind, title, add }) => (
            <section key={kind} className={styles.card}>
              <h2>{title}</h2>
              {result.data.groups
                .filter((group) => group.kind === kind)
                .map((group) => (
                  <EntryRow key={group.id} entity="group" id={group.id} name={group.name} canManage={canManage} />
                ))}
              {canManage && <AddEntryForm entity="group" kind={kind} label={add} />}
            </section>
          ))}
          {branches.ok && branches.data.length > 0 && (
            <section className={styles.card}>
              <h2>Estado das filiais</h2>
              <p className={styles.hint}>É o estado que define qual PMC vale em cada filial.</p>
              {branches.data.map((branch) => (
                <BranchLocationRow key={branch.id} branch={branch} canManage={canLocate} />
              ))}
            </section>
          )}
          <section className={styles.card}>
            <h2>Canais de venda</h2>
            {result.data.channels.map((channel) => (
              <EntryRow key={channel.id} entity="channel" id={channel.id} name={channel.name} canManage={canManage} />
            ))}
            {canManage && <AddEntryForm entity="channel" label="Novo canal" />}
          </section>
        </>
      )}
    </>
  );
}
