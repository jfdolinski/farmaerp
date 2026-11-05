# FarmaERP

ERP para farmácia com PDV híbrido offline-first, retaguarda web e API de integrações.
A referência do projeto é o [docs/base.md](docs/base.md).

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `apps/pdv` | PDV em Flutter (Windows, Linux, Android) |
| `apps/api` | API em NestJS |
| `apps/web` | Retaguarda em Next.js |
| `db` | Migrations, triggers, funções, views, seed e testes do banco |
| `packages/error-catalog` | Catálogo de erros usado pelo banco, pela API e pelo PDV |

Para publicar, siga o guia em [docs/deploy.md](docs/deploy.md).

## Primeiros passos (Windows, PowerShell)

Requisitos: Docker Desktop, Node 24 ou superior e Flutter.

```powershell
Copy-Item .env.example .env
npm install
npm run db:up
npm run db:migrate
npm run db:seed
```

## Comandos

| Comando | O que faz |
|---|---|
| `npm run db:up` / `db:down` | Sobe ou para o PostgreSQL |
| `npm run db:migrate` | Aplica as migrations pendentes |
| `npm run db:seed` | Cria os dados de desenvolvimento |
| `npm run db:reset` | Apaga o banco local e recria tudo do zero |
| `npm run test:db` | Testa triggers, RLS e conformidade em um banco separado (`farmaerp_test`) |
| `npm run test:api` | Testa a API |
| `npm run test:integration` | Testa a API contra o banco real, em um banco próprio recriado a cada execução |
| `npm run test:catalog` | Testa o catálogo de erros |
| `npm run catalog:generate` | Gera o catálogo em Dart para o PDV depois de alterar o JSON |
| `npm run test:images` | Constrói as imagens Docker e testa um ambiente publicado de ponta a ponta |
| `npm run test:outage` | Derruba o PostgreSQL local e confere se a API sobrevive (requer o build da API) |
| `npm run dev:api` | Sobe a API em http://localhost:3001 (`GET /health`) |
| `npm run dev:web` | Sobe a retaguarda em http://localhost:3000 |

No PDV, dentro de `apps/pdv`: `flutter analyze`, `flutter test` e `flutter run -d windows`.

## Banco de dados

**Hierarquia**

```text
Societária:  Grupo econômico > Empresa > Filial > Terminal
Filiais:     Grupo econômico > Grupo de filial > Região > Filial
```

Todo estabelecimento, inclusive a matriz, é uma filial com CNPJ completo.
A empresa guarda só a raiz de 8 caracteres.

**Criar uma tabela nova**

1. Crie um arquivo numerado em `db/migrations`. As migrations só andam para a frente e não mudam depois de publicadas.
2. Inclua as colunas `id`, `created_at`, `updated_at`, `deleted_at`, `version`, `updated_by` e `trace_id`.
3. Chame `CALL app.apply_table_standard('public.nome_da_tabela');` para aplicar o padrão.
4. Crie as políticas de RLS, as permissões de `farmaerp_app` e a view `v_nome_da_tabela` com `security_invoker = true`.
5. Registre os `CHECK` e os índices únicos em `dbConstraints` no catálogo de erros.

Os testes `db/tests/conformity.test.mjs` e `db/tests/error-catalog.test.mjs` falham se uma tabela ficar fora desse padrão.

**Acesso aos dados**

- A API conecta como `farmaerp_app` e usa `DatabaseService.withContext`, que abre a transação e define `app.user_id` e `app.trace_id`.
- Sem esse contexto, nenhuma linha é retornada.
- As consultas do dia a dia usam as views `v_*`, que mostram só registros ativos.
- A API é responsável por informar o usuário autenticado: o banco confia nesse valor.

## Erros e logs

**Criar um erro novo**

1. Acrescente o código em `packages/error-catalog/catalog.json`. Cada área tem uma faixa: `FA0xx` geral, `FA1xx` padrão das tabelas, `FA2xx` estrutura multifilial.
2. No banco, levante o erro com a mesma mensagem do catálogo:
   `RAISE EXCEPTION '<mensagem>' USING ERRCODE = 'FA203', DETAIL = '<detalhe técnico>';`
3. Rode `npm run catalog:generate` e versione o arquivo gerado no PDV.

A API responde sempre no formato `{ code, message, action, retryable, traceId }`.

**Rastreio**

- O ID é um UUID v7 gerado na origem da operação e enviado no cabeçalho `X-Trace-Id`. A API o devolve na resposta.
- O mesmo ID aparece no log da API, em `trace_id` na linha alterada e em `app=api:<id>` nos logs do Postgres.
- O operador vê `Código FA203 · Ref. a1b2c3d4`: a referência são os 8 últimos caracteres do ID.

**Logs**

- A API grava JSON na saída padrão. O PDV grava em `logs/`, na pasta de dados do app, com retenção de 14 dias e limite total de 50 MB.
- Nunca registre corpo de requisição, query string, CPF, senha, PIN, token, certificado ou biometria. Campos com esses nomes são mascarados.

## Terminais

**Testar o pareamento em desenvolvimento**

1. Suba o banco e a API: `npm run db:up`, `npm run db:migrate`, `npm run db:seed` e `npm run dev:api`.
2. Suba a retaguarda: `npm run dev:web`, e abra http://localhost:3000/terminais.
3. Em `apps/pdv`, rode `flutter run -d windows`. O endereço da API muda com `--dart-define=API_URL=...`.
4. Entre na retaguarda com `admin@farmaerp.test` e a senha `farmaerp-dev-123`, que só existe em desenvolvimento, e digite o código mostrado no PDV. O seed também cria `gerente@farmaerp.test` e `operador@farmaerp.test`, com a mesma senha, escolha a filial e aprove o terminal.

**Autenticação do terminal**

O aparelho guarda uma chave Ed25519, responde a um desafio assinado e recebe um token de 15 minutos. A situação do terminal é consultada a cada requisição, então um bloqueio vale no próximo contato, em até 60 segundos. Um terminal offline só descobre o bloqueio ao reconectar.

**Variáveis de ambiente da API**

- `TERMINAL_TOKEN_SECRET`: assina desafios e tokens, com ao menos 32 caracteres. Sem ela, a API não inicia.
- `TRUST_PROXY=true`: usar atrás do proxy do EasyPanel, para o limite de tentativas ver o IP real.

## Código humano

O UUID é a identidade do registro. O código humano serve para tela, cupom e atendimento.

| Item | Formato | Quem gera |
|---|---|---|
| Produto e cliente | Sequência única por grupo econômico (`10452`) | Banco central |
| Venda | Número do terminal + contador (`2-000123`) | PDV, mesmo offline |

**Aplicar a uma tabela nova**

1. Inclua as colunas `economic_group_id` e `code bigint NOT NULL`.
2. Chame `CALL app.apply_human_code('public.nome_da_tabela', 'nome_do_item');`.

**Regras**

- A API não informa o código: um valor enviado é ignorado.
- Só a migração de dados, conectada como `farmaerp_migrator`, grava códigos antigos, e o contador avança para não repeti-los.
- O número do terminal é atribuído na aprovação, é único na filial e nunca é reaproveitado, com limite de 999.
- Inclusões com `ON CONFLICT DO NOTHING` consomem um número. Na sincronização, confira antes se o UUID já existe.

## Login e usuários

- **Quem entra:** usuários com e-mail e acesso liberado. Operadores de caixa podem existir sem e-mail: o `code` deles será usado no PDV na Etapa 5.
- **Senha:** Argon2id, calculado na API, com no mínimo 10 caracteres. Esqueceu? O administrador gera uma senha temporária, com troca obrigatória.
- **Tentativas:** 10 por minuto por IP, e bloqueio da conta por 15 minutos depois de 5 falhas.
- **Sessão:** 8 horas sem uso, e no máximo 12 horas. A API confere no banco a cada requisição, então desativar um usuário vale na hora.
- **Histórico:** `auth_event` é imutável. O IP é apagado depois de 90 dias, na rotina que roda a cada login.

## Perfis e permissões

- **Permissões:** o catálogo fica na tabela `permission` e só muda por migration. Os perfis ficam por grupo econômico e as permissões de vários perfis se somam.
- **Onde vale:** um perfil vale em todas as filiais do usuário ou em uma só. Sem filial informada, `app.has_permission(código)` só considera perfis válidos em todas.
- **Administrador:** perfil de sistema, com todas as permissões, inclusive as de módulos futuros. Não pode ser alterado, e o grupo nunca fica sem um ativo.
- **Escalada:** ninguém concede o que não tem, nem age sobre quem tem mais poder.
- **Histórico:** vínculos de perfil são só incluídos ou excluídos logicamente, então cada linha guarda quem fez e quando.

**Criar uma permissão nova**

1. Acrescente a linha em `permission` por uma migration nova.
2. Use `app.has_permission('modulo.acao', filial)` nas políticas e funções do banco. Quem decide é sempre o banco.
3. Na retaguarda, use `can(user, 'modulo.acao')` só para mostrar ou esconder botões.
4. Acrescente aos testes de `db/tests/permissions.test.mjs`.
