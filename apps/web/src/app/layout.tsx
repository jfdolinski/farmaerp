import type { Metadata } from "next";
import { Suspense } from "react";
import { EnvironmentBanner } from "./environment-banner";
import "./globals.css";

export const metadata: Metadata = {
  title: "FarmaERP",
  description: "Retaguarda do FarmaERP",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="pt-BR">
      <body>
        <Suspense fallback={null}>
          <EnvironmentBanner />
        </Suspense>
        {children}
      </body>
    </html>
  );
}
