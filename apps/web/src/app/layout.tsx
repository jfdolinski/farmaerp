import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "FarmaERP",
  description: "Retaguarda do FarmaERP",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}
