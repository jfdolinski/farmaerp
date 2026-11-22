import path from "node:path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  cacheComponents: true,
  // O XML da nota chega por ação do servidor, com até 5 MB.
  experimental: { serverActions: { bodySizeLimit: "6mb" } },
  partialPrefetching: true,
  // Imagem enxuta para o Docker, incluindo os pacotes do monorepo.
  output: "standalone",
  outputFileTracingRoot: path.join(__dirname, "../../"),
};

export default nextConfig;
