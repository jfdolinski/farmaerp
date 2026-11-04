# Construir a partir da raiz do repositório: a retaguarda usa packages/.
#   docker build -f apps/web/Dockerfile .
FROM node:24.22.1-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
COPY db/package.json db/
COPY packages/error-catalog/package.json packages/error-catalog/
RUN npm ci --no-audit --no-fund
COPY apps/web apps/web
COPY packages/error-catalog packages/error-catalog
ENV NEXT_TELEMETRY_DISABLED=1
RUN mkdir -p apps/web/public && npm run build -w apps/web

FROM node:24.22.1-slim
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
WORKDIR /app
COPY --from=build /app/apps/web/.next/standalone ./
COPY --from=build /app/apps/web/.next/static apps/web/.next/static
COPY --from=build /app/apps/web/public apps/web/public
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "apps/web/server.js"]
