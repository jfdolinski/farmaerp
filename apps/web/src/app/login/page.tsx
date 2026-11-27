import type { Metadata } from "next";
import { Suspense } from "react";
import { apiFetch } from "@/lib/api";
import { LoginForm } from "./form";
import login from "./login.module.css";

export const metadata: Metadata = { title: "Entrar · FarmaERP" };

type SearchParams = Promise<{ next?: string; expired?: string }>;

export default function LoginPage({ searchParams }: { searchParams: SearchParams }) {
  return (
    <Suspense fallback={<main className={login.screen} />}>
      <LoginScreen searchParams={searchParams} />
    </Suspense>
  );
}

/** Tela de entrada: a imagem da plataforma (se houver) ao fundo e o cartão de entrada à direita. */
async function LoginScreen({ searchParams }: { searchParams: SearchParams }) {
  const [{ next, expired }, image] = await Promise.all([
    searchParams,
    apiFetch<{ sha256: string | null }>("/public/login-image/info"),
  ]);
  const version = image.ok ? image.data.sha256 : null;
  return (
    <main className={`${login.screen} ${version ? login.withImage : ""}`}>
      {version && (
        // eslint-disable-next-line @next/next/no-img-element -- imagem própria, já reduzida no envio
        <img className={login.backdrop} src={`/login/imagem?v=${version}`} alt="" />
      )}
      <span className={login.mark}>
        <span className={login.cross} aria-hidden="true" />
        FarmaERP
      </span>
      <section className={login.card} aria-labelledby="entrar-titulo">
        <h1 id="entrar-titulo">Entrar</h1>
        <p className={login.lead}>Use seu e-mail e sua senha da retaguarda.</p>
        <LoginForm next={next} expired={expired === "1"} />
      </section>
    </main>
  );
}
