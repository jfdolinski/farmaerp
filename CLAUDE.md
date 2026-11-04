# FarmaERP

ERP para farmácia com PDV híbrido offline-first, retaguarda web e API de integrações.
Documento de referência obrigatório: docs/base.md. Siga-o em todas as decisões.

## Stack
- PDV: Flutter (Windows, Linux, Android), banco local SQLite enxuto
- Banco central: PostgreSQL
- API: NestJS (TypeScript)
- Retaguarda: Next.js (TypeScript)
- Ambiente local: Docker Compose (Docker Desktop no Windows)

## Estrutura do monorepo
- apps/pdv      → Flutter
- apps/api      → NestJS
- apps/web      → Next.js
- db/           → migrations, triggers, procedures, views (versionados)
- docs/         → documentação do projeto

## Regras inegociáveis
- Regras de negócio e conformidade ficam no banco (triggers, procedures, views), não na aplicação.
- Chave primária UUID v7 em todas as tabelas; uuid no Postgre, blob 16 bytes no SQLite.
- Toda tabela tem: created_at, updated_at, deleted_at (exclusão lógica), version, updated_by.
- Nunca apagar registros fisicamente.
- Multifilial: grupo econômico > empresa (CNPJ) > filial > terminal; Row Level Security por filiais permitidas.
- Estoque só muda via movimentações imutáveis; saldo atualizado por trigger.
- Sincronização PDV → central sempre via outbox, idempotente pelo UUID.
- Views comuns para consultas; views materializadas para relatórios pesados.
- Usabilidade é prioridade: mensagens claras ao operador, detalhe técnico só no log.

## Publicação (produção)
- Parte online (PostgreSQL, API NestJS, retaguarda Next.js) roda numa VPS Hostinger com Ubuntu, gerenciada pelo EasyPanel.
- Cada parte é um serviço no EasyPanel: PostgreSQL, API e web, com deploy a partir do repositório Git (Dockerfile em cada app).
- Domínios e HTTPS configurados pelo próprio EasyPanel.
- PostgreSQL acessível só pela rede interna dos serviços, sem porta pública.
- Backup diário do banco configurado no EasyPanel, com cópia fora da VPS.
- Variáveis de ambiente e segredos definidos no EasyPanel, nunca versionados.
- Migrations rodam automaticamente no deploy da API.

## Distribuição e atualização automática
- PDV desktop com instalador simples (Windows: instalador "avançar e concluir"; Linux: pacote único).
- Serviço de atualizações na VPS publica a versão atual de cada app, com arquivos assinados digitalmente.
- O PDV verifica e baixa atualizações em segundo plano e só aplica em momento seguro (nunca durante uma venda): fechamento de caixa ou próxima abertura.
- Antes de liberar a nova versão, roda as migrações do SQLite; em caso de falha, volta para a versão anterior.
- Liberação gradual pela retaguarda: primeiro terminais de teste, depois a rede; retaguarda mostra a versão de cada terminal.
- Apps de celular pela Play Store, com atualização dentro do app e versão mínima obrigatória para mudanças críticas.
- Retaguarda web atualiza a cada deploy.
- O usuário nunca precisa rodar comandos nem reinstalar para atualizar.

## Forma de trabalho
- Implementar uma etapa do docs/base.md por vez, na ordem.
- Antes de codar, apresentar o plano e aguardar aprovação.
- Escrever testes para triggers, procedures e sincronização.
- Ao terminar uma etapa, resumir o que foi feito e o que ficou pendente.
- Idioma: código e nomes de tabela em inglês; comentários, documentação e mensagens ao usuário em português.
- Ambiente de desenvolvimento: Windows 11, PowerShell.
