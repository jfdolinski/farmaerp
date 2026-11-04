# Construir a partir da raiz do repositório: a API usa db/ e packages/.
#   docker build -f apps/api/Dockerfile .
FROM node:24.22.1-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
COPY db/package.json db/
COPY packages/error-catalog/package.json packages/error-catalog/
RUN npm ci --no-audit --no-fund
COPY apps/api apps/api
COPY packages/error-catalog packages/error-catalog
RUN npm run build -w apps/api

FROM node:24.22.1-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
COPY db/package.json db/
COPY packages/error-catalog/package.json packages/error-catalog/
RUN npm ci --omit=dev --no-audit --no-fund -w apps/api -w db -w packages/error-catalog

FROM node:24.22.1-slim
ENV NODE_ENV=production
ENV PORT=3001
WORKDIR /app
COPY --from=deps /app/node_modules node_modules
COPY --from=deps /app/package.json package.json
COPY apps/api/package.json apps/api/package.json
COPY --from=build /app/apps/api/dist apps/api/dist
COPY db/package.json db/package.json
COPY db/scripts db/scripts
COPY db/migrations db/migrations
COPY db/seeds db/seeds
COPY db/bootstrap/sql db/bootstrap/sql
COPY packages/error-catalog packages/error-catalog
COPY --chmod=755 apps/api/docker-entrypoint.sh docker-entrypoint.sh
USER node
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["./docker-entrypoint.sh"]
