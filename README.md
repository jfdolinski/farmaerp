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
| `npm run catalog:import -- arquivo.json` | Importa itens do Catálogo de produtos, que não é o catálogo de erros |
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

**Clientes separados (plataforma)**

- Cada grupo econômico é um cliente do sistema, com dados só dele: usuários, perfis, produtos, clientes, estoque, vendas, caixa, crediário, descontos e terminais. A RLS e as funções filtram pelo grupo de quem está logado. Só o catálogo de produtos (`catalog_*`) é comum, e nenhum cliente o altera.
- **Empresa nova de outro dono:** cadastrada pelo administrador da plataforma em `/plataforma` (`app.create_tenant`). Nascem juntos o grupo (com os perfis padrão), a empresa, a primeira filial e o administrador da empresa, com senha temporária que aparece uma vez e é trocada na primeira entrada. Erros: FA847 e FA848, além de CNPJ inválido (FA211), CNPJ já cadastrado (FA213) e e-mail já usado (FA406).
- **O administrador da plataforma** (`platform_admin`) vê só a lista dos clientes (`app.list_tenants`: nome, raízes de CNPJ, quantidades de filiais e usuários, e-mail do administrador), nunca os dados deles. Na homologação e na produção, é o administrador criado no deploy (`BOOTSTRAP_ADMIN_EMAIL`), mesmo que já exista outro; em desenvolvimento, também `admin@farmaerp.test` (a senha de exemplo só existe lá). A sessão informa `platformAdmin` só para a tela; o banco confere de novo.
- **Outro CNPJ do mesmo dono:** continua em `/empresas`, dentro do mesmo cliente, compartilhando produtos, clientes e crediário.
- O teste `db/tests/platform.test.mjs` confere, tabela por tabela, que um cliente não vê nada do outro.

Todo estabelecimento, inclusive a matriz, é uma filial com CNPJ completo.
A empresa guarda a raiz de 8 caracteres do CNPJ principal, mas a filial pode ter um CNPJ de outra raiz. O certificado A1 é conferido com o CNPJ da própria filial.

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

**Banco local e descida (central → PDV)**

- **Banco local:** SQLite criptografado (SQLite3MultipleCiphers, escolhido em `hooks.user_defines` do `pubspec.yaml`), em `farmaerp.db` na pasta de dados do app. A chave nasce no aparelho e fica no cofre do sistema, junto da chave do terminal. Se o arquivo não abrir com a chave (cofre apagado), ele é guardado de lado como `.ilegivel-<data>` e a carga recomeça.
- **Migrações locais:** lista em `lib/local/local_database.dart`, controlada por `PRAGMA user_version`. Só se acrescenta no fim. UUID fica em blob de 16 bytes; dinheiro em centavos e quantidade em milésimos, sem ponto flutuante.
- **O que desce:** dados fiscais da filial e as séries do terminal (sem certificado nem CSC), usuários com perfil na filial (com permissões e limites, sem senha nem e-mail), produtos ativos e por encomenda (bloqueados só com saldo; inativos não descem) com preço efetivo da filial, códigos de leitura e tributação em vigor e futura, e o estoque por lote.
- **Como a central sabe o que mudou:** triggers anotam cada mudança em `sync_change` (uma linha por item, com o número da transação). O cursor do PDV é o `xmin` do snapshot: transação demorada nunca fica para trás do que o PDV já leu.
- **Rota:** `POST /terminals/sync/pull` com o token do terminal, em pacotes de 1.000 itens compactados com gzip. Sem `cursor`, faz a carga inteira; a resposta traz `until`, `next` e, no primeiro pacote, `total`. Item com `data` vazio sai da cópia local.
- **No PDV:** a descida roda depois de cada sinal de vida aceito. Cada pacote é aplicado numa transação junto com a posição da janela: se o PDV fechar no meio, continua do último pacote gravado. A tela mostra "Preparando a loja" com o progresso até a carga inicial terminar.
- **Formato:** `app.pdv_sync_format()` muda quando o que desce muda de forma; o PDV então refaz a carga inteira e limpa o que não veio.
- **Teste de ponta a ponta:** com a API local no ar, `PDV_E2E_API=http://localhost:3001 flutter test test/sync_e2e_test.dart` dentro de `apps/pdv`.

**Subida (PDV → central)**

- **Outbox:** tabela `outbox` do banco local. A operação grava o item com `LocalDatabase.transaction(...)` + `enqueue(...)`: se a operação falha, o item some junto. Cada item tem UUID v7 e uma sequência local.
- **Envio:** depois de cada sinal de vida aceito, o PDV sobe a outbox (antes da descida), em ordem, em pacotes de até 100 itens e 64 KB, por `POST /terminals/sync/push`. O sinal de vida informa quantos itens esperam envio.
- **Na central:** `app.pdv_push` grava um recibo por item em `sync_receipt`, pelo UUID: reenvio responde `duplicate` e não aplica de novo. Item fora do formato recusa o pacote inteiro (FA956), porque é defeito do PDV.
- **Conflitos:** item que o banco recusa (código do catálogo) vira conflito em `sync_conflict` e a fila segue. Eles aparecem em `/sincronizacao` para quem tem `sync.view`; quem tem `sync.resolve` marca como resolvido, com a explicação. O Gerente recebe as duas permissões.
- **Reaplicar:** quem tem `sync.resolve` pode aplicar de novo o item do conflito (`app.retry_sync_conflict`), com o mesmo conteúdo e em nome do terminal de origem. É o caminho quando o motivo já foi corrigido, por exemplo um PDV atualizado antes da API (FA959). Se passar, o recibo vira aplicado e o conflito fica resolvido; se o banco recusar de novo, o conflito continua aberto com o motivo e o autor da última tentativa. O recibo só muda de conflito para aplicado. A lista não mostra o código do rosto (fica "(oculto)").
- **Primeiro tipo, os logs:** avisos e erros do PDV (nunca `info`), já sem dados pessoais, vão para `terminal_log` com o rastreio da operação. Até 5.000 esperam envio; acima disso ficam só no arquivo local. Logs entregues saem da fila local depois de 7 dias.
- **Tipos novos:** cada tipo ganha uma procedure no banco, chamada pelo `CASE` de `app.pdv_apply_item` (usada pela subida e pelo reaplicar). Tipo desconhecido vira conflito (FA959).

**Clientes no PDV**

- **Busca com internet, em dois passos:** `POST /terminals/customers/search` (nome com 3 letras ou mais, código ou CPF/CNPJ, com ou sem pontuação) devolve até 20 clientes com o documento mascarado. `GET /terminals/customers/:id` traz o escolhido inteiro. A busca vai no corpo, para o CPF não parar em log de acesso.
- **Guardado e acompanhado:** o escolhido fica no banco local criptografado, e a central anota em `pdv_customer_cache` que este terminal o guardou. Daí em diante a descida leva as mudanças e a exclusão só desses clientes.
- **Sem internet:** `CustomerService` busca entre os clientes já guardados no terminal e avisa que a lista não veio da central.
- **Crediário:** quando existir, os clientes com débito descem para todos os terminais (Etapa 7).

**Acompanhamento na retaguarda**

- A central anota em `terminal_status` a descida concluída (`last_pull_at` e o cursor entregue), a carga inicial (`initial_load_at`) e a subida (`last_push_at`).
- A tela Terminais mostra, para cada terminal, a carga inicial, a última descida e a última subida. Mostra também o que espera para subir (informado pelo PDV), o que espera para descer (mudanças depois do cursor, contadas até 10.000) e o link para os conflitos abertos.

**Variáveis de ambiente da API**

- `TERMINAL_TOKEN_SECRET`: assina desafios e tokens, com ao menos 32 caracteres. Sem ela, a API não inicia.
- `FISCAL_ENCRYPTION_KEY`: 32 bytes em base64, criptografa certificado A1 e CSC. Sem ela, a API sobe, mas o envio de certificado e de CSC responde FA915.
- `TRUST_PROXY=true`: usar atrás do proxy do EasyPanel, para o limite de tentativas ver o IP real.

### Versões e atualização automática (central)

- **Versões** (`app_release`): da plataforma, iguais para todos os clientes. O CI envia o instalador para `POST /releases` (token `RELEASE_UPLOAD_TOKEN`, arquivo no corpo, dados na query). A API confere a **assinatura Ed25519** antes de gravar (chaves públicas em `scripts/release/update-keys.json`; a privada fica só no segredo do GitHub) e o SHA-256 e o tamanho depois de receber. O arquivo vai para `RELEASES_DIR`. Repetida: FA874; inválida: FA869; envio sem token ou pasta: FA876.
- **Texto assinado:** `farmaerp-release-v1`, app, sistema, versão, SHA-256 e tamanho, um por linha (`scripts/release/release-format.mjs`, `apps/api/src/releases/release-signature.ts` e o PDV).
- **Chave:** `node scripts/release/generate-update-key.mjs <arquivo fora do repositório>` gera o par; a pública vai em `update-keys.json` (e em `update-keys.ts`, conferido por teste). Fora da produção, os testes aceitam também `UPDATE_TEST_PUBLIC_KEY`.
- **Liberação gradual:** a versão nasce só para os terminais de teste. Em `/plataforma/versoes`, o administrador da plataforma libera para a rede ou retira (FA877; retirada não volta). Em Terminais, cada cliente marca o **anel** do terminal (teste ou rede, FA878).
- **Terminal:** `GET /terminals/updates?platform=&current=` devolve a versão mais nova do anel dele, acima da que ele tem e que ele não tenha precisado desfazer; `GET /terminals/updates/{id}/file` baixa (com retomada por Range; FA875 se não puder); `POST /terminals/updates/{id}/report` informa baixou, aplicou, voltou à anterior ou falhou (`terminal_update_event`).
- **Retaguarda:** em Terminais, a versão, o anel e a última atualização de cada terminal; em `/plataforma/versoes`, quantos terminais estão em cada versão, quantos aplicaram e quantos voltaram.

### Instalador e atualização automática (PDV)

- **Instalador Windows** (`apps/pdv/installer/farmaerp-pdv.iss`, Inno Setup 6): "avançar e concluir", por usuário em `%LOCALAPPDATA%ProgramsFarmaERP PDV`, sem pedir administrador. Guarda uma cópia de si mesmo em `{app}installer`, usada para voltar a esta versão. Os dados (banco local e chave do terminal, em `%APPDATA%`) ficam na desinstalação e na atualização.
- **Gerar na máquina:** em `apps/pdv`, `powershell -ExecutionPolicy Bypass -File tool/build-installer.ps1 -Version 1.2.3 -ApiUrl https://... -AppEnv homologation` (precisa do Inno Setup 6). Sai em `build/installer/FarmaERP-PDV-Setup-1.2.3.exe`.
- **Publicar uma versão:** crie a tag `pdv-v1.2.3` no `main`. O workflow "Versão do PDV" roda os testes, gera o instalador, guarda como artefato, assina (`UPDATE_SIGNING_KEY`) e envia à homologação (`RELEASE_UPLOAD_TOKEN`), só para os terminais de teste. Ele não roda em PR (a máquina Windows conta minutos em dobro); para só gerar o instalador, rode-o à mão (Actions → Versão do PDV → Run workflow).
- **No PDV** (`lib/update/`): a cada 30 minutos (e na abertura) pergunta à central, baixa em segundo plano retomando de onde parou, confere tamanho, SHA-256 e assinatura (chaves em `update_signature.dart`, iguais às de `scripts/release/update-keys.json`, conferido por teste). Arquivo que não confere é apagado e informado, e a versão não é tentada de novo.
- **Momento seguro:** a versão baixada é aplicada depois do fechamento de caixa ou na próxima abertura do PDV, nunca com venda em andamento. Antes, o PDV copia o banco local e o instalador da versão atual; abre o instalador sem perguntas e fecha. O instalador reabre o PDV.
- **Volta à versão anterior:** se a versão nova não abrir o banco local (migração), o PDV devolve a cópia do banco, reinstala a anterior e informa a central ("voltou à versão anterior"). Sem o instalador anterior, mostra FA879 (os dados ficam preservados). Se o instalador não concluir, o PDV abre na versão antiga e informa "falhou".
- **Migração do banco local:** a falha de migração não põe mais o banco de lado (isso fica só para a chave errada); o erro sobe para a volta à versão anterior.
- **Só no build de release e no Windows.** O pacote do Linux vem depois.
- **Sem certificado de assinatura de código** por enquanto: na primeira instalação o Windows mostra "Editor desconhecido" (Mais informações → Executar assim mesmo). As atualizações não passam por isso e continuam protegidas pela assinatura própria.

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

### Limites de valor e liberação de supervisor

- **Tipos de limite:** catálogo fixo em `limit_type` (desconto na venda em %, sangria, venda no crediário e perda ou ajuste de estoque em R$). Os de venda e de caixa ficam configuráveis agora e passam a valer no PDV.
- **Limite por perfil:** `role_limit`, editado em `/perfis`. Quem tem vários perfis na filial fica com o maior (`app.user_limit`). Sem limite configurado, vale zero. O Administrador não tem teto. O Gerente nasce com valores de exemplo (10% de desconto, R$ 1.000 de sangria, R$ 500 de crediário e R$ 500 de perda ou ajuste).
- **Liberação:** acima do limite, `app.require_value_release` pede um supervisor. A API confere a senha dele (código ou e-mail), com o mesmo bloqueio de cinco erros do login; o banco confere se ele faz a mesma operação na filial, se o limite dele cobre o valor e se não é a mesma pessoa. Fica em `supervisor_release`: quem pediu, quem liberou, o valor, os dois limites, o motivo e a movimentação.
- **Estoque:** perda, ajuste e inventário passam pelo limite de perda ou ajuste, pelo valor da movimentação ao custo médio da filial. Produto sem custo médio não pede liberação.
- **Desconto:** `app.discount_check` diz se o desconto passa sozinho, pede liberação ou só passa com `sales.discount_override` (acima do máximo do produto no motor de regras). O PDV usa a partir da Etapa 4.
- **Auditoria:** `/liberacoes`, com `releases.view` na filial, mostra também as liberações de custo da nota de compra.
- **Offline:** usuários, perfis, permissões e limites já descem para o PDV (Etapa 3). A liberação sem internet depende de conferir a credencial no aparelho, que chega com a autenticação da Etapa 5.

## Produtos

- **Catálogo:** tabelas globais `catalog_*`, sem grupo econômico. A API só lê; quem escreve é `npm run catalog:import`, com o papel dono das tabelas.
- **Imagens do Catálogo:** cada item do arquivo pode trazer `"images": [{ "file": "caminho.jpg", "main": true }]`, com caminho relativo ao JSON.
    - `npm run catalog:prepare-images -- entrada.json saida.json` converte JPEG, PNG ou WebP de até 5 MB (conferidos pelos bytes) para WebP de até 800 px e de até 200 px, sem metadados. A `sharp` é dependência só de desenvolvimento.
    - `npm run catalog:import` aceita o arquivo já preparado em qualquer lugar, inclusive no servidor, ou prepara na hora onde a `sharp` estiver instalada.
    - As imagens ficam em `catalog_product_image` (bytea). A mesma imagem é reconhecida pelo SHA-256 do original e não grava de novo; a que sai da lista é retirada; sem o campo `images`, nada muda.
    - A API entrega em `GET admin/catalog-images/:id/full|thumb`, com cache longo e ETag, e a retaguarda repassa em `/imagens/:id/:tamanho`, com a sessão.
- **Produto da loja:** único na rede. Pode existir sem Catálogo, marcado como tal, até ser vinculado.
- **Código de barras:** não se repete no grupo. Todo produto ativo termina a transação com um principal, que precisa estar ativo na leitura do PDV. Códigos fora do padrão GTIN são marcados como internos.
- **Fracionamento:** o do código de barras prevalece sobre o do produto. Use `app.effective_fraction`.
- **Escrita:** toda alteração passa por funções `app.*`, que conferem `products.manage`. Produto e estrutura são da rede, então um perfil de uma filial só não os altera.
- **Preço:** só é incluído, e a última linha vale. Use `app.effective_price`: a exceção da filial prevalece sobre a rede, e preço vazio em filial encerra a exceção.
- **PMC:** por estado e região especial. Use `app.effective_pmc`: o valor mais recente vale, da loja ou do Catálogo, e sem valor para a região especial vale o do estado.
- **Limite de PMC:** com a flag ligada, salvar preço acima do PMC é bloqueado. Um PMC novo, menor que o preço já salvo, só avisa na grade.
- **Status por filial:** ativo, somente encomenda, bloqueado ou inativo, com motivo obrigatório e histórico. Toda filial tem uma linha, que nasce ativa. Sair de inativo exige `products.reactivate` e a senha de quem reativa.
- **Busca:** esconde o produto inativo em todas as filiais que o usuário enxerga, até marcar "Mostrar inativos".

**Importar o Catálogo**

O arquivo é uma lista JSON, e `sourceKey` identifica o item na origem. Importar de novo atualiza o que mudou. Se um item for recusado, nada é gravado e o erro aponta qual foi.

```json
[
  {
    "sourceKey": "origem-123",
    "name": "Nome padrão do produto",
    "activeIngredient": "Princípio ativo",
    "manufacturer": "Fabricante",
    "msRegistration": "1234567890123",
    "controlledClass": "B1",
    "ncm": "30049099",
    "cest": "1300100",
    "barcodes": ["7890000000017"],
    "pmc": [{ "state": "SP", "value": 15.5 }, { "state": "AM", "region": "manaus_free_zone", "value": 12 }],
    "taxes": [
      {
        "regimes": [1, 4],
        "states": ["SP", "PR"],
        "validFrom": "2026-12-01",
        "cfop": "5405",
        "origin": 0,
        "icmsCsosn": "500",
        "pisCst": "49",
        "cofinsCst": "49"
      }
    ]
  }
]
```

Em `controlledClass`, deixe vazio para não controlado ou use `A1`, `A2`, `A3`, `B1`, `B2`, `C1` a `C5`, `D1` ou `antimicrobial`. Em `region`, use `free_trade_area` ou `manaus_free_zone`.

**Tributação (`taxes`)**

Cobre a venda interna. Cada entrada vale para os regimes (`1` Simples Nacional, `2` Simples com excesso de sublimite, `3` Regime Normal, `4` MEI) e UFs da lista, a partir de `validFrom`.

| Campos | Observação |
|---|---|
| `regimes`, `states`, `validFrom`, `cfop`, `origin`, `pisCst`, `cofinsCst` | Obrigatórios. CFOP de venda interna (5xxx) |
| `icmsCsosn` ou `icmsCst` | Regimes 1 e 4 usam CSOSN; 2 e 3 usam CST |
| `icmsRate`, `icmsBaseReduction`, `fcpRate`, `benefitCode` | Alíquota obrigatória nos CST 00, 10, 20 e 70 |
| `stBaseMode`, `stMva`, `stRate`, `stBaseReduction`, `stFcpRate` | Modalidade e alíquota obrigatórias nos códigos com ST; recusados nos códigos sem ST |
| `pisRate`, `cofinsRate` | Obrigatórios nos CST 01 e 02 |
| `ibsCbsCst`, `classTrib`, `ibsStateRate`, `ibsCityRate`, `cbsRate` | Todos juntos ou nenhum. `ibsCbsReduction` é opcional dentro do grupo |

- **Sem repetir linha:** valor igual ao vigente não gera linha nova.
- **Correção:** a mesma vigência com outro valor substitui a anterior, que continua guardada.
- **Item sem `taxes`:** mantém as regras que já tem.
- **Recusas:** campo desconhecido, combinação repetida e alíquota com mais de quatro casas cancelam a importação inteira.
- **Dados reais:** os valores do seed são fictícios. A tributação real precisa vir do contador ou de um fornecedor de dados fiscais.

## Motor de regras

Responde qual regra vale para um produto em uma filial, e por quê. Os módulos chamam o banco:

```sql
SELECT * FROM app.resolve_product_rule('commission', produto, filial);
```

- **Ordem de decisão:** primeiro o nível (produto, grupo de preço, fabricante, subcategoria, categoria, departamento, grupo de precificação, grupo de comissão, padrão da loja). No mesmo nível, a filial vence a rede, depois a maior prioridade, depois a mais recente.
- **Sem regra:** não volta nenhuma linha, e cada módulo decide o que fazer. Não existe valor padrão escondido.
- **Produto sem Catálogo:** o nível do fabricante não se aplica, porque o fabricante dele é texto livre.
- **Histórico:** o valor de uma regra não muda. Editar encerra a regra e cria outra.
- **Permissão de leitura:** a função roda como quem chama, então a RLS vale. As funções dos módulos rodam como dono e enxergam tudo.

**Criar um tipo de regra**

1. Acrescente a linha em `rule_type` por uma migration nova, com unidade e faixa válida.
2. Chame `app.resolve_product_rule` com o código do tipo no módulo que usa a regra.
3. Acrescente aos testes de `db/tests/product-rules.test.mjs`.

**Descontos automáticos (Etapa 7)**

- **Dez tipos (`discount_rule.kind`):** percentual fixo, promoção (com início e fim), leve X pague Y, progressivo por quantidade (a partir da N-ésima unidade), forma de pagamento (só quando a venda inteira é paga nela), grupo de clientes, convênio, aniversariante do mês, faixa de valor da compra (sobre o valor sem desconto) e cupom (o código é comparado em caixa alta, sem espaços).
- **Alvo:** os mesmos níveis do motor, mais "todos os produtos" (`store_default`). Uma regra vale na rede ou em uma filial.
- **Combinação, por item:** as acumuláveis se somam. Entre as exclusivas vale a de maior desconto (no empate, a de menor id), e ela só fica se der mais que a soma das acumuláveis (no empate, ficam as acumuláveis). Cada regra é arredondada em centavos (metade para cima), e o desconto nunca passa do item. Leve e pague e progressivo contam só as unidades inteiras.
- **Um cálculo, dois lugares:** `app.discount_calculation(regras, itens, contexto)` é uma função pura, em JSON. O PDV faz a mesma conta em Dart, e os dois são conferidos pelos mesmos casos em `packages/discount-cases/cases.json`. `app.auto_discounts(filial, itens, contexto)` monta a conta com os cadastros da central (regras em vigor, hierarquia do produto, grupo e aniversário do cliente).
- **Cadastro:** `/descontos`, com `rules.manage` (filial ou rede). Editar é encerrar e criar outro (`app.create_discount_rule`, `app.end_discount_rule`). O simulador (`app.simulate_discounts`, `rules.view`) mostra, para uma venda de exemplo, quais descontos valem e por quê. Erros: FA826 a FA831, além dos do motor (FA702 a FA704).
- **Grupos de clientes:** em `/descontos`, com `customers.manage`. O grupo de cada cliente fica na ficha dele (`app.set_customer_group`). Grupo com clientes ou com desconto em vigor não sai (FA105).
- **Descida para o PDV:** as regras em vigor ou futuras da filial e da rede descem como o 6º tipo (`discount_rule`); encerrada ou vencida desce vazia. O produto desce com a hierarquia (`discount_subject`) e o cliente guardado, com o grupo.
- **No caixa:** o PDV refaz os descontos automáticos a cada mudança na venda (itens, quantidade, cliente, pagamento e cupom), com a mesma conta da central (`lib/pos/discount_engine.dart`). Cada item mostra as regras que valeram, e o comprovante lista cada uma.
  - **Forma de pagamento:** ao escolher a forma, o valor sugerido já vem com o desconto dela (por exemplo, PIX). Pagamento misto tira esse desconto.
  - **Cupom:** campo na tela de pagamento. Código que não dá desconto nenhum na venda é recusado (FA832).
  - **Desconto manual:** vai por cima dos automáticos e só até o que sobra do item. O limite do operador e o máximo do produto valem só sobre a parte manual.
  - **Orçamento puxado no caixa:** o desconto do orçamento é refeito na mesma fração; o manual é o que passa dos automáticos de agora.
- **Na central:** cada item traz a parte automática (`auto_discount`) e as regras com o valor de cada uma (`sale_item_discount`), e a venda traz o cupom. A central refaz a conta com as regras da hora da venda (inclusive as encerradas depois). Se o PDV deu mais que o esperado, a venda vale e fica o alerta "Desconto automático acima do que as regras davam". O detalhe da venda mostra as regras e o cupom.
- **Formato 4 da descida:** os PDVs refazem a carga para receber as regras, a hierarquia dos produtos e o grupo dos clientes.

**Crediário (Etapa 7, banco e retaguarda)**

- **Conta:** uma por cliente (`credit_account`), aberta na ficha do cliente com `credit.manage` (perfil Gerente). Tem filial (os parâmetros dela valem), limite e situação. Abrir, mudar o limite, bloquear, liberar e mudar os vencimentos fica no histórico (`credit_account_event`), com quem, quando, o valor anterior, o sugerido e o motivo (obrigatório no limite e no bloqueio).
- **Limite sugerido:** média mensal das compras dos últimos 6 meses vezes o fator da filial (`app.credit_suggested_limit`).
- **Dependentes:** marcados na ficha ("pode comprar no crediário", `customer_dependent.credit_allowed`), compram na conta do titular, e a parcela guarda quem comprou.
- **Parâmetros por filial** (`credit_policy`, em `/crediario`, só com `credit.policy`): multa (até 2%, teto do CDC), juros ao mês (até 10%), máximo de parcelas (padrão 3), dias de atraso até bloquear (padrão 30), fator do limite e vencimentos. Sem cadastro, valem os padrões: multa 2%, juros 1% ao mês e fatura mensal. **O contador confirma multa e juros antes de produção.**
- **Vencimentos:** padrão da filial, com exceção por conta, valendo só para compras novas.
  - **Fatura mensal (padrão):** fecha no dia 25 e vence no dia 10. A compra até o fechamento entra na fatura que fecha no mês; depois, na seguinte. As parcelas caem nas faturas seguintes.
  - **Dias corridos:** a cada intervalo (padrão 30 dias) a partir da compra.
  - O centavo que sobra da divisão fica na primeira parcela.
- **Encargos:** multa uma vez por parcela, sobre o que estava em aberto no vencimento. Juros simples por dia (taxa mensal / 30) sobre o valor em aberto, contados desde o vencimento ou desde o último recebimento. Centavos arredondados metade para cima.
- **Recebimento:** no caixa de qualquer loja, em dinheiro, cartão ou PIX (tipo de subida `credit_payment`). Abate primeiro multa e juros de todas as parcelas vencidas e depois o valor das parcelas, da que vence antes para a que vence depois (`credit_allocation`). Entra no esperado do caixa. Se o PDV recebeu mais que o devido (outro caixa recebeu antes), o dinheiro já entrou: o excesso fica no recebimento e vira alerta do caixa.
- **Um cálculo, dois lugares:** `app.credit_schedule`, `app.credit_position` e `app.credit_allocate` são funções puras, conferidas pelos mesmos casos que o PDV vai usar (`packages/credit-cases/cases.json`). `app.credit_states` dá a situação de cada parcela em aberto no formato dessas funções.
- **Venda no crediário** (forma `store_credit`): o PDV manda as parcelas que mostrou ao cliente, que viram `credit_installment` (não mudam). Fora do formato, sem conta ou dependente de outro grupo: conflito (FA962, FA834, FA004). Conta bloqueada, atraso além do prazo, acima do disponível, dependente sem autorização, parcelas acima do máximo ou vencimentos diferentes da conta da central: a venda vale (já aconteceu) e fica o alerta.
- **Descida:** quem deve desce para todos os terminais da rede, com o limite, os parâmetros, as parcelas em aberto e os dependentes autorizados. Quando o débito acaba, sai dos terminais que não guardaram o cliente. Formato 5 da descida.
- **Retaguarda:** `/crediario` lista as contas (com débito, em atraso, bloqueadas ou todas, e busca) e os parâmetros por filial. A ficha do cliente mostra o resumo, as parcelas com multa e juros de hoje, os recebimentos, os dependentes e o histórico. Erros: FA834 a FA839.
- **No PDV:**
  - **Forma de pagamento "Crediário":** aparece só para cliente com conta. Mostra o disponível, o número de parcelas (até o máximo da filial), os vencimentos de cada uma e, se houver, quem compra (titular ou dependente autorizado). O valor sugerido é o que cabe no disponível. As contas são as mesmas da central (`lib/pos/credit_engine.dart`, conferido por `packages/credit-cases/cases.json`).
  - **Recusas no caixa:** sem conta (FA834), conta bloqueada (FA840), parcela vencida além do prazo da filial (FA841), acima do disponível (FA842) e parcelas fora do permitido (FA843).
  - **Limite do operador** ("venda no crediário", por perfil): acima dele, outra pessoa com limite que cubra libera com código e PIN, ou pela câmera (FA845). A liberação sobe no pagamento e fica em `supervisor_release` (`sales.store_credit`); sem ela, a venda vale e fica o alerta "Crediário acima do limite do operador".
  - **Sem internet:** o crediário que desceu, mais as vendas, os recebimentos e as devoluções deste terminal que a central ainda não devolveu (outbox não enviada ou enviada depois da última descida do cliente).
  - **Recebimento:** "Receber crediário (F11)", com o caixa sem venda em andamento. Busca entre os clientes com crediário do terminal, mostra cada parcela com a multa e os juros de hoje, aceita dinheiro, cartão ou PIX até o total em aberto (FA844) e imprime o comprovante. O dinheiro entra na gaveta (conta para a sangria).
  - **Comprovante da venda:** as parcelas com os vencimentos, quem comprou, quem liberou e a linha para a assinatura do cliente.
  - **Devolução de venda no crediário:** destino "Abatimento no crediário". Na central vira um recebimento do tipo `return` (não passa pelo caixa), que abate na ordem do crediário. Se passar do débito, o excesso fica registrado e vira alerta do caixa. Venda que não foi no crediário não abate (FA846).
  - **Banco local versão 13:** o crediário do cliente (`customer.credit`) e a devolução com o destino novo.

**Cashback (Etapa 7, banco e retaguarda)**

- **Percentual:** do motor de regras, tipo "Cashback" (produto, família, categoria... ou loja), na hora da venda.
- **Só com consentimento:** sem o consentimento de cashback do cliente na hora da venda, não ganha nem usa (FA849).
- **Ganho:** um lote por venda, sobre o valor pago sem a parte paga com cashback (`cashback_entry` do tipo `earn`), com carência e validade da rede. Arredondado no centavo.
- **Parâmetros da rede** (`cashback_policy`, em `/descontos`, com `rules.manage` em todas as filiais): carência (padrão 0 dia), validade (padrão 90 dias) e quanto da compra o cashback pode pagar (padrão 50%). Erro: FA853.
- **Uso, só com internet:** o PDV reserva o valor na central (`app.pdv_cashback_reserve`: consentimento, saldo e máximo; FA849 a FA851) e a venda confirma a reserva. Desistência libera (`app.pdv_cashback_release`, FA852). Reserva não confirmada em 2 horas volta para o saldo. Venda que chega sem reserva válida vale e usa o saldo de agora, com o alerta "Cashback usado sem reserva válida ou acima do máximo".
- **Lotes:** o uso tira do lote que vence antes (`cashback_allocation`). O vencido sai do saldo por um lançamento de expiração, gravado na próxima operação do cliente que der certo.
- **Devolução:** o ganho da venda é estornado na proporção (do que sobrou do lote; o que o cliente já usou fica registrado como diferença). O cashback usado na venda volta como lote novo, na proporção acumulada das devoluções, para fechar no centavo (`sale_return.cashback_refund`). O destino da devolução (crédito, convênio, dinheiro ou crediário) recebe o resto (`sale_return.refund_amount`): a sangria de devolução, o crédito de devolução e o abatimento no crediário usam esse valor.
- **Retaguarda:** extrato e saldo na ficha do cliente (quem vê clientes). Erros: FA849 a FA854.
- **No PDV:**
  - **Forma de pagamento "Cashback":** aparece com o cliente identificado. Ao escolher, o PDV busca na central o saldo, o consentimento e o máximo de uso, e sugere o que dá para usar. Lançar reserva o valor na central; tirar o pagamento, voltar aos itens, trocar ou tirar o cliente libera a reserva. Sem internet, não usa (FA855); sem consentimento, FA849; acima do saldo ou do máximo, FA850 e FA851.
  - **Comprovante:** "Cashback ganho" estimado (percentual de cada item, que desce com o produto, sobre o que foi pago sem cashback), e a carência, se houver. A central confirma o valor.
  - **Devolução:** a parte do cashback (a mesma conta acumulada da central, com os dados da venda: cashback usado, total já devolvido e cashback já devolvido) volta como cashback; o comprovante mostra "Volta como cashback" e "Para o destino". A sangria e o crédito de devolução feitos sem internet usam o valor para o destino.
  - **Banco local versão 14:** o percentual de cashback do produto e a parte do cashback da devolução. Formato 6 da descida.

**Fatura do convênio (Etapa 7)**

- **Dia de fechamento** por convênio (`agreement.closing_day`, de 1 a 28, padrão 25; FA860). A prévia sugere fechar no último dia de fechamento que já passou; dá para escolher outra data, até hoje.
- **O que entra:** vendas pagas no convênio e devoluções dessas vendas com destino convênio, como abatimento negativo pelo valor que vai para o destino (`refund_amount`, sem a parte que volta como cashback), até a data e que ainda não estão em fatura (`app.agreement_open_items`). Venda ou devolução atrasada, de PDV que ficou sem internet, entra na próxima fatura.
- **Fechar** (`app.close_agreement_invoice`): grava `agreement_invoice` (período, total, quem fechou) e `agreement_invoice_item` (cada venda ou devolução, com a matrícula). Um item só entra numa fatura ativa (índice único). Data no futuro ou não depois da fatura anterior: FA857. Nada a faturar: FA856.
- **Pagar** (`app.pay_agreement_invoice`, data até hoje e observação): a fatura fica paga e não muda mais (FA858). O limite usado do cliente deixa de contar as compras dela, e o cliente desce de novo para os PDVs.
- **Cancelar** (`app.cancel_agreement_invoice`, com motivo, FA302): só a última fatura fechada e não paga do convênio (FA858). As vendas voltam para o próximo fechamento; a fatura cancelada continua com os itens para consulta.
- **Limite usado** (`app.agreement_used`): compras no convênio menos devoluções, que não estão em fatura paga. Desce para o PDV com os convênios do cliente (`used`). Venda que chega acima do limite (PDV sem internet) vale e vira alerta "Convênio acima do limite do cliente" (`agreement_limit`). Formato 7 da descida.
- **Retaguarda:** `/convenios` mostra o dia de fechamento e o link "Faturas" de cada convênio. `/convenios/{id}`: dia de fechamento, prévia (por cliente e por lançamento) com "Fechar a fatura" e a lista das faturas. `/convenios/faturas/{id}`: detalhe por cliente e por lançamento, "Imprimir" (sem menu nem formulários), "Baixar CSV" (ponto e vírgula, vírgula decimal, UTF-8 para planilha), pagamento e cancelamento. Tudo com `agreements.manage` em todas as filiais.
- **PDV:** a forma "Convênio" mostra o disponível de cada convênio do cliente: limite menos o usado da central, as vendas no convênio deste terminal que a central ainda não devolveu e o que já está no carrinho. Acima disso, FA859.

## Estoque

- **Fonte da verdade:** a tabela `stock_movement`, que nunca é alterada. Correção é uma movimentação contrária, com `reversal_of` apontando para a original.
- **Saldo:** `stock_balance`, por filial, produto e lote, mantido só pelo trigger. `app.stock_balance_divergences()` compara o saldo com a soma das movimentações, e qualquer linha ali é defeito.
- **Saldo negativo:** só por venda, porque o PDV pode vender offline. As demais saídas são recusadas se faltar saldo.
- **Lote:** cadastro próprio por filial e produto. O controle é ligado por filial e produto, e em controlado é sempre obrigatório. Ligar ou desligar exige o saldo do outro modo zerado.
- **MS do lote:** herda o do Catálogo. Pode ser editado, com histórico, e `ms_original` guarda o primeiro valor.
- **Baixa por vencimento:** `app.allocate_batches` distribui a quantidade pelos lotes que vencem antes, e em empate pelo que entrou primeiro. Lote vencido nunca entra.
- **Lote escolhido à mão:** `app.check_chosen_batch` recusa vencido e, fora da ordem, exige `stock.batch_override`, marcando `fefo_override` na movimentação. Vale na transferência e valerá na venda. Perda e ajuste não passam por ela.
- **Transferência:** imediata, com saída e entrada ligadas por `transfer_group`. No destino, o lote de mesmo número é usado ou criado com a validade e o MS da origem. Não substitui a nota fiscal entre CNPJs.
- **Inventário simples:** a diferença entre o contado e o saldo vira movimentação do tipo `inventory`. Contagem igual não gera nada.
- **Status e saldo:** `app.product_availability` diz se o produto vende e se entra na compra automática em cada filial, e o aviso para o vendedor. Lote vencido não conta como saldo vendável.
- **Seed:** em tabela com trigger de validação, confira com `NOT EXISTS` antes de incluir. O trigger roda antes do `ON CONFLICT`, e o seed roda a cada deploy de homologação.

## Vendas

- **Onde nasce:** no PDV, mesmo sem internet. Turno (`cash_session_open`) e venda (`sale`) sobem pela outbox, em ordem, e a central aplica com `app.sync_apply_cash_open` e `app.sync_apply_sale`.
- **Código humano:** número do terminal + contador do terminal (`2-000123`). O contador é do PDV; a central recusa número repetido (FA963).
- **Conflito ou alerta:**
  - O que não fecha vira conflito e não é aplicado (FA962): totais, troco, formato, turno de outro terminal, item de outro grupo.
  - O que fecha mas merece atenção é aplicado, porque a venda já aconteceu, e vira alerta em `sale_alert`: preço diferente do da central na hora da venda, desconto acima da regra ou do limite sem liberação válida, operador sem `sales.sell`, estoque negativo, produto que não estava ativo, convênio sem vínculo com o cliente.
- **Estoque:** baixa por item, com o lote escolhido no PDV (controlados) ou pelo vencimento mais próximo. O que faltar sai do último lote, negativo. Produto que exige lote e ainda não tem nenhum sai sem lote, com alerta.
- **Desconto liberado no PDV:** vira `supervisor_release` com a ação `sales.discount`, visível em `/liberacoes`.
- **Pagamentos:** dinheiro (com troco), cartão de crédito e de débito e PIX registrados à mão, e convênio. TEF e PIX integrados entram quando os fornecedores forem escolhidos.
- **Nota fiscal:** a venda fica com a nota pendente de emissão até a Etapa 8 (NFC-e e NF-e).
- **Retaguarda:** `/vendas` lista por período e filial, com o filtro "Só com alerta", e mostra o detalhe com itens, lotes baixados, pagamentos e alertas. Exige `sales.view` (Gerente); o Operador de caixa tem `sales.sell`.

**Caixa no PDV**

- **Entrada:** código do usuário + PIN de 4 a 6 números, conferido no próprio PDV (funciona sem internet).
  - Quem pode gerar senha temporária para a pessoa define o PIN em `/usuarios` (`POST /admin/users/:id/pin`).
  - A API recusa PIN com todos os números iguais ou em sequência (FA965) e guarda só o hash PBKDF2-SHA256 (210 mil rodadas, sal próprio) em `user_pin`.
  - O hash desce para as filiais da pessoa (formato 2 da descida).
  - Cinco PINs errados seguidos bloqueiam a pessoa neste terminal por 5 minutos (FA967). Código desconhecido e PIN errado dão a mesma mensagem.
  - A regra é a mesma da senha temporária: só age sobre quem tem perfis que a pessoa cobre. Um Gerente de loja não define o PIN de quem tem perfil na rede inteira.
- **PINs de desenvolvimento (seed):** Administrador 2580, Operador Centro 2468, Gerente Centro 1357.
- **Autenticação (Etapa 5):** toda entrada e toda liberação no PDV passam por um serviço único (`PosAuth`).
  - **Forma de entrar por pessoa:** qualquer uma, só PIN, só câmera ou só digital (`user_account.pdv_auth_mode`). Quem pode definir o PIN define a forma em `/usuarios`, em "Entrada no PDV" (`POST /admin/users/:id/auth-mode`, FA819). Ela desce para as filiais da pessoa. Só muda por `app.set_user_auth_mode`, que registra em `auth_event`.
  - Quem não entra com PIN recebe FA820 ao digitar o PIN.
  - **Liberação do gerente:** quem é só câmera ou só digital e não tem o aparelho no terminal (ou ele falhou) entra com a liberação de quem tem "Liberar a entrada no PDV" (`users.release_login`, perfil Gerente). O gerente digita o código e o PIN dele. Precisa ser outra pessoa (FA821). A câmera chega no PR 5B; a digital, depois da escolha do leitor.
  - **Registro:** cada entrada, falha, bloqueio por tentativas, liberação e identificação de vendedor sobe pela outbox (`auth_event`) para `pdv_auth_event`, sem PIN e sem dados pessoais. Entrada por uma forma que não é a da pessoa, ou liberada por quem não tinha a permissão, vale (já aconteceu, talvez sem internet) e fica marcada.
  - **Retaguarda:** `/entradas-pdv` lista por período e filial, com filtro "só as marcadas". Quem vê precisa de "Ver usuários".
- **Rosto (Etapa 5, PR 5B, só no Windows por enquanto):**
  - **Entrada:** com câmera, a tela inicial lê o rosto sozinha. A pessoa fica de frente (prova de vida), vira o rosto devagar para um lado e volta. O PDV compara com os rostos cadastrados neste terminal, sem internet. "Entrar de outra forma" volta para o código, com o PIN ou com a liberação do gerente. Quem é só PIN não entra pela câmera (FA824); rosto desconhecido dá FA825.
  - **Cadastro:** no ícone de rosto da barra de cima. Quem autoriza digita o código e o PIN e precisa de "Cadastrar o rosto e a digital no PDV" (`users.biometrics`, perfil Gerente; FA822). Depois vêm o código da pessoa, o termo de consentimento (versão `biometria-v1`) e a leitura com 5 quadros. O cadastro vale na hora no terminal e sobe pela outbox (`face_enrollment`) com o consentimento (`biometric_consent`). Cadastro que chega atrasado não substitui um rosto mais novo nem volta depois de a pessoa revogar o consentimento (FA833).
  - **O que é guardado:** só o código numérico do rosto (128 números, 512 bytes, `face_template`), nunca a imagem. Os quadros da câmera ficam só na memória. O código desce para os PDVs das filiais da pessoa e fica no banco local criptografado. A aplicação não lê as tabelas do rosto; a retaguarda vê só a situação (`app.face_enrollments`).
  - **Liberar pela câmera:** as telas que pedem código e PIN de quem libera (desconto, venda sem estoque, controlado, sangria, devolução, vendedor com PIN e liberação da entrada) têm o botão "Liberar pela câmera". A câmera reconhece a pessoa (prova de vida e o desafio), o código dela entra no campo e a tela confirma sem PIN. O PDV guarda um vale de uso único, válido por 60 segundos e só para essa pessoa. A conferência de sempre aceita o vale no lugar do PIN e aplica as mesmas regras de permissão e limite, registrando a liberação como "câmera". Quem é só PIN não libera pela câmera (FA824).
  - **Apagar:** em `/usuarios`, "Apagar rosto" (a própria pessoa ou quem pode definir o PIN dela; FA823 se não houver). O consentimento fica revogado e o rosto sai dos PDVs na próxima sincronização.
  - **Câmera:** abre só enquanto a tela de entrada ou o cadastro estão abertos. Sem câmera, ou com falha, o PDV segue com o PIN e a liberação do gerente.
  - **Modelos (em `apps/pdv/assets/face`):** YuNet 2023mar (detecção, MIT), MiniFASNet int8 da Facenox (prova de vida, Apache 2.0) e SFace 2021dec int8 (reconhecimento, Apache 2.0 na conversão da OpenCV). O motor fica atrás de `FaceEngine`, para trocar de modelo ou por um SDK comercial. **Antes de produção, o jurídico decide sobre o SFace:** o repositório original não declara licença e os pesos foram treinados em bases de pesquisa.
  - **ONNX Runtime:** antes do primeiro build do PDV no Windows, rode `powershell -ExecutionPolicy Bypass -File apps/pdv/tool/fetch_onnxruntime.ps1`. O script baixa o pacote oficial da Microsoft no NuGet (1.32.0), confere o SHA-512 e extrai a DLL e os cabeçalhos para `apps/pdv/third_party/onnxruntime` (fora do Git). O plugin tentaria baixar do GitHub, que não está disponível.
  - **Teste dos modelos no Windows:** `flutter test integration_test -d windows` (roda os três modelos e mostra os tempos; sem câmera e sem rosto de pessoa).
- **Turno:** abertura com o fundo de troco, gravada no banco local e na outbox na mesma transação (`cash_session_open`).
- **Venda:**
  - leitura do código de barras (com o fracionamento do código), do código do produto ou busca por nome, princípio ativo e fabricante, sem acento (FTS5 do SQLite);
  - avisos de encomenda, bloqueado e sem estoque;
  - controlados pedem a receita e o farmacêutico (abaixo).
- **Pagamento:** dinheiro (com troco), cartão de crédito e de débito (bandeira e autorização opcionais) e PIX. O troco só sai do dinheiro.
- **Número da venda:** contador do terminal, que continua do último número que a central recebeu (`last_sale_number` nos dados fiscais), mesmo se o banco local se perder.
- **Comprovante não fiscal:** 48 colunas para bobina de 80 mm.
  - Impressora térmica em ESC/POS pela fila do Windows (tipo RAW, página 860 para os acentos), escolhida no ícone de impressora do caixa.
  - Sem impressora configurada, sai em PDF em `Documentos\FarmaERP\comprovantes`.
  - Falha na impressão não desfaz a venda e mostra "Reimprimir".
- **Atalhos:** F2 vai para a leitura, F3 puxa o orçamento, F4 identifica o cliente, F6 sangria, F7 suprimento, F8 fecha o caixa, F9 devolução, F10 abre o pagamento, Esc volta.
- **Foco:** o cursor sempre volta para o campo obrigatório da vez.
  - Entrada: código e PIN; PIN errado volta para o PIN.
  - Turno: fundo de troco.
  - Venda: vendedor, leitura, painel aberto (receita do controlado, venda sem estoque) e valor do pagamento.
  - Nas janelas, o foco começa no primeiro campo obrigatório e, num erro, vai para o campo com problema. Ao fechar a janela, volta para a tela.
- **Campos de número** (quantidade, valores, contagem, plaquinha): ao entrar, o valor fica selecionado e o operador digita por cima.
- **Busca de produto com autocompletar:** a partir de 3 letras, as sugestões aparecem enquanto digita. As setas escolhem, Enter adiciona e Esc fecha.
  - O espaço vale como "%": "dip 500" acha Dipirona Sódica 500 mg, e pedaço do meio da palavra também vale.
  - Ignora acentos e maiúsculas; o que começa as palavras vem primeiro.
  - Código de barras, código do produto e cupom do orçamento vão direto com Enter.
- **Consulta do produto:** o botão de informação, na busca e em cada item, mostra os dados de cadastro que o terminal tem (códigos de barras, princípio ativo, fabricante, registro no MS, NCM, CEST, lista de controlado, situação, preço, desconto máximo, fracionamento, estoque e lotes), mesmo sem internet.
- **Cliente com autocompletar:** a partir de 3 letras, busca sozinho e Enter escolhe o marcado. Na janela do orçamento (F3), a lista de pendentes filtra enquanto digita.
- **Aparência do PDV:** no ícone de paleta da barra de cima, a fonte (tamanho de 80% a 160%, tipo e negrito) e a cor base. Vale só para o terminal, fica no banco local e é aplicada na hora.
  - **Tipo do terminal:** a cor base ganha um tom por tipo: orçamento claro, caixa médio, autoatendimento forte. A barra de cima mostra o ícone e o nome ("Caixa 1 · Operador") e uma faixa com o tipo em letras grandes; a barra inferior também mostra o tipo. Assim cada terminal é reconhecido de longe, sem depender só da cor.
  - **Caixa alta:** todo o PDV aparece em caixa alta, inclusive o que se digita (senha e PIN ficam como estão). As telas usam `Text`, `TextField` e `InputDecoration` de `lib/ui/caps.dart`, que convertem na hora de mostrar. O comprovante impresso não muda.
- **Barra inferior fixa:**
  - loja e número do caixa;
  - operador e hora da abertura do turno;
  - vendedor da venda atual;
  - internet, envios pendentes e hora da última sincronização;
  - data e hora;
  - versão.

  Sem valores do turno, por causa do fechamento cego.
- **Desconto no item:** em R$ ou %.
  - Dentro do limite de desconto do operador (perfis) e do máximo do produto (motor de regras, que desce com o produto e vence com a regra), vale na hora.
  - Acima, um supervisor libera no próprio terminal com código, PIN e motivo. Ele precisa ser outra pessoa, ter limite que cubra o desconto e, acima do máximo do produto, `sales.discount_override` (dele ou do operador).
  - A liberação vai com a venda e aparece em `/liberacoes`.
- **Venda sem estoque:**
  - Com o saldo local zerado, o caixa só vende se o PDV estiver sem sincronizar há mais que o tempo mínimo e o gerente (`sales.zero_stock_release`) autorizar com código e PIN. Senão recusa (FA977).
  - O tempo mínimo é por filial (padrão 30 min, `structure.manage`) com exceção por terminal (`terminals.approve`), na tela Terminais.
  - Produto por encomenda só avisa.
  - A venda chega com o registro e vira o alerta "Vendido sem estoque com o PDV sem internet".
- **Estoque nas filiais:** consulta com internet (`GET /terminals/stock/:produto`), pelo ícone de loja no item ou na busca.
- **Cliente e convênio:**
  - O cliente identificado vai na venda e no comprovante, com o documento mascarado.
  - Os convênios dele descem com o cadastro.
  - O pagamento em convênio aparece só com cliente que tenha convênio, com a matrícula e o disponível do limite (veja "Fatura do convênio").

**Vendedor e orçamento**

- **Vendedor:** cada venda no caixa e cada orçamento novo pedem o código de quem atende (para a comissão, na Etapa 7).
  - Com o parâmetro da filial ligado, o vendedor digita também o PIN.
  - Precisa poder orçar (`sales.quote`) ou vender (`sales.sell`); sem isso, FA880 no PDV e alerta na venda.
  - No autoatendimento, o vendedor é fixo no terminal (`fixed_seller_id`).
- **Perfil do terminal** (caixa, orçamento ou autoatendimento): escolhido na aprovação e trocado em Terminais, "Mudar o perfil" (`terminals.approve`). Desce nos dados fiscais e o PDV muda de modo na próxima sincronização, mesmo sem internet depois.
- **Terminal de orçamento:** sem entrada de operador nem turno.
  - O vendedor monta como no caixa: busca, cliente, desconto com liberação e estoque nas filiais.
  - Controlado e falta de estoque só avisam: a receita e a venda são do caixa.
  - Ao concluir, plaquinha (cartão numerado da loja, de 1 a 9999) e/ou cupom com o código `O<terminal>-<número>` em código de barras (Code 128). Sem plaquinha, o cupom sai sempre.
- **Na central:** o orçamento sobe pela outbox (`quote`); fora do formato, FA883.
  - A plaquinha segura um orçamento aberto por loja. Usada de novo, o anterior fica substituído (ou vencido, se já tinha passado da validade). Um orçamento que chega atrasado já chega substituído.
  - **Validade:** parâmetro da filial em dias, em Terminais, "Orçamento e vendedor" (0: até o fim do dia; até 90).
- **Retaguarda:** `/orcamentos` lista por período, filial e situação (aberto, virou venda, substituído, vencido), com a conversão; o detalhe mostra os itens e as liberações. Exige `sales.view`.
- **Perfis:** Operador de caixa, Gerente e Farmacêutico orçam; o perfil novo Balconista só orça.
- **No caixa (F3, ou lendo o cupom no campo de leitura):** com internet, mostra os orçamentos pendentes da loja e puxa pela plaquinha ou pelo código do cupom.
  - Vem com o vendedor e o cliente do orçamento.
  - Os itens entram com o preço de agora e o desconto do orçamento na mesma fração, com a liberação que veio. Sem liberação, o desconto fica no que o operador dá sozinho.
  - Item sem estoque ou que não está no terminal fica de fora, com aviso. Controlado abre a receita, um por vez.
  - Mensagens próprias: não encontrado nesta loja (FA885), já virou venda (FA886), vencido (FA887), plaquinha usada em outro orçamento (FA888), venda em andamento (FA889) e sem internet (FA890; aí o operador passa os produtos do cupom um a um).
  - A venda leva o orçamento (`quote_id`). Na central, o orçamento aberto, válido na hora da venda e da mesma loja vira venda. Senão, a venda vale e fica o alerta "Venda de orçamento que já não estava aberto".
- **Recálculo:** a venda é recalculada a cada mudança (itens, quantidade, cliente, forma de pagamento): preço atual da loja e o desconto de cada item na mesma fração. Se o total mudar com pagamento lançado, o pagamento é refeito. As regras por cliente e por forma de pagamento entram nesse mesmo recálculo na Etapa 7.

**Devolução**

- **No caixa (F9):** só na loja da compra e vinculada à venda.
  - O operador digita o código do comprovante da venda. Com internet, vale venda de qualquer caixa da loja; sem internet, só as deste terminal.
  - Escolhe quanto volta de cada item. O valor é a parte do total do item; a última devolução do item fecha no centavo.
  - Informa o motivo e o destino do valor:
    - crédito para nova compra (veja "Crédito de devolução" abaixo);
    - abatimento na fatura do convênio (só se a venda teve convênio; entra na próxima fatura);
    - dinheiro ao cliente.
  - Sai o comprovante com o documento `D<terminal>-<número>` em código de barras.
- **Quem faz:** quem tem "Fazer devolução" (`sales.return`, perfil Gerente). Sem ela, outra pessoa com a permissão libera com código e PIN (FA895).
- **Prazo:** é parâmetro da filial, em dias (padrão 7, em Terminais). Fora do prazo, sempre precisa da liberação de outra pessoa com a permissão (FA898).
- **Controlado** não volta no caixa (FA893); fica para a manutenção do SNGPC (Etapa 8).
- **Dinheiro:** sai por uma sangria de devolução, que pede o documento.
  - O valor vem do documento e, na central, a devolução fica paga: o ciclo se fecha.
  - Documento já pago, de crédito, de outra loja ou com valor diferente: a sangria vale (o dinheiro já saiu) e vira alerta do caixa.
  - Depois de uma devolução em dinheiro, a sangria já abre com o documento.
- **Na central:** a devolução sobe pela outbox (`sale_return`) e é conferida no banco. Erros dão FA891 a FA894 e FA897.
  - O estoque volta para os lotes que saíram na venda.
  - Sem a permissão (ou fora do prazo sem a liberação de outra pessoa), a devolução vale e fica o alerta na venda.
- **Retaguarda:** `/devolucoes` lista por período, filial e destino, com a situação do pagamento, o saldo do crédito, o cliente, o convênio a abater e quem liberou. O detalhe da venda mostra as devoluções dela.
  - O filtro "Abatimento no convênio" lista as devoluções que abatem na fatura de cada convênio (veja "Fatura do convênio").

**Crédito de devolução**

- **No pagamento:** forma "Crédito de devolução". O operador digita (ou lê) o documento `D...` e busca o crédito.
  - O valor sugerido é o menor entre o saldo e o que falta. Acima do saldo, não lança (FA873). O resto vai em outra forma de pagamento.
  - Com internet, o saldo vem da central, menos o que este terminal usou e ainda não enviou. Sem internet, valem só os créditos feitos neste terminal.
  - Crédito usado por inteiro, de outra loja, em dinheiro ou desconhecido: FA872.
  - O comprovante mostra "Crédito D...". A venda leva o `return_id` em cada pagamento com crédito.
- **Na central:** o crédito vale só na loja da devolução. Pagamento acima do saldo, de outra loja ou com documento que não é de crédito vale (a venda já aconteceu) e fica o alerta "Crédito de devolução usado sem saldo ou fora das regras".
- **Retaguarda:** o detalhe da devolução mostra o uso do crédito (venda, data e valor), e o pagamento no detalhe da venda leva ao documento.

**Sangria, suprimento e fechamento**

- **Sangria em três níveis**, pelo limite de sangria (`cash_withdrawal`) dos perfis, que desce com o usuário:
  - até o limite do operador, ele faz sozinho;
  - acima, outra pessoa com limite que cubra o valor libera no próprio terminal com código e PIN (o supervisor);
  - acima do limite do supervisor, o gerente (FA991 e FA992).
- A sangria nunca passa do dinheiro que deve estar na gaveta (FA993) e exige valor e motivo (FA994). Sai um comprovante com as assinaturas para ir com o envelope.
- **Suprimento:** troco que entra na gaveta, com motivo e comprovante; não pede liberação.
- **Fechamento com conferência cega:** o operador informa o que contou em dinheiro, cartão de crédito, cartão de débito e PIX, sem ver o esperado (FA997), confirma e volta para a entrada.
  - O comprovante do fechamento mostra só o contado.
  - A central calcula o esperado: dinheiro = fundo de troco + vendas em dinheiro (menos o troco) + suprimentos − sangrias; as outras formas, a soma das vendas. Convênio não passa pelo caixa.
  - A diferença fica em `cash_session_count`; qualquer diferença vira alerta.
- **Na central:** movimentos e fechamento sobem pela outbox (`cash_movement` e `cash_session_close`).
  - Fora do formato ou de turno de outro terminal: conflito FA995. Turno já fechado: FA996.
  - A sangria acima do limite sem liberação válida vale (o dinheiro já saiu) e vira alerta. A liberação válida aparece em `/liberacoes` como "Sangria do caixa".
- **Retaguarda:** `/caixas` lista os turnos por período, filial e situação, com vendas, sangrias, suprimentos e a diferença. O detalhe mostra a conferência por forma (no turno aberto, o esperado de agora), os movimentos com quem liberou e os alertas. Exige `sales.view`.
- **No seed:** o Operador Centro não tem limite de sangria (toda sangria pede liberação); o Gerente Centro (PIN 1357) libera até R$ 1.000.

**Controlados**

- **No caixa:** o controlado lido entra na venda como os outros itens (desconto, quantidade etc.), marcado "Controlado: falta a receita (pedida ao finalizar)". Ao finalizar a venda, antes do pagamento, o caixa pede a receita (ou a liberação pendente) de cada controlado, um por vez; depois do último, segue para o pagamento. "Voltar aos itens" mantém o item sem receita; "Não vender" tira o item. Sem receita nem liberação, a venda não é gravada (FA986). Cada controlado fica no seu item, com receita e lote próprios.
  - **Receita de outro item:** "Usar a receita de …" traz receita, prescritor, comprador e paciente de outro controlado da venda, só com o mesmo tipo de receita. Notificação vale para um só medicamento: o número e a data ficam para preencher.
  - **Orçamento:** o controlado entra com os outros itens do orçamento puxado; a receita é pedida ao finalizar.
  - **Receita:** tipo (sugerido pela lista do produto: A → notificação A, B1 → notificação B, B2 → B2, C2 → retinoide, C3 → talidomida, antimicrobiano → receita de antimicrobiano, demais → controle especial), número (obrigatório nas notificações e no antimicrobiano) e data.
  - **Validade:** 30 dias da data da receita; antimicrobiano, 10. Vencida ou com data no futuro é recusada (FA987).
  - **Prescritor:** nome, conselho (CRM, CRO, CRMV, COREN, CRF, RMS), número e UF.
  - **Comprador:** nome, documento (RG, CPF, CNH, passaporte ou outro), número, órgão emissor e UF. Obrigatório nos psicotrópicos (listas da Portaria 344); no antimicrobiano é opcional, mas vai inteiro ou não vai (migration 0056, também no complemento do SNGPC e no arquivo enviado).
  - **Paciente:** opcional; idade e sexo obrigatórios no antimicrobiano.
  - **Lote:** só os lotes com saldo e não vencidos da cópia local, o que vence primeiro antes. Quantidade acima do saldo do lote é recusada (FA988).
  - **Liberação:** código e PIN de quem tem `controlled.dispense` (perfil Farmacêutico; FA985 para os demais).
- **Prescritor do cadastro:** na receita, "Buscar no cadastro" acha o profissional por nome (sem acento) ou pelo número no conselho e preenche nome, conselho, número e UF. Prescritor que não está no cadastro pode ser cadastrado na hora ("Cadastrar prescritor"): entra na cópia local e sobe pela outbox.
- **Pendente (estoque negativo):** sem lote com saldo para a quantidade, o farmacêutico libera com um motivo, sem os dados da receita. Com lote com saldo, a liberação pendente é recusada (FA989). Os dados do SNGPC são completados na manutenção do SNGPC.
- **Na central:** `controlled_dispensing` guarda receita, comprador, lote e farmacêutico, e não muda depois.
  - Dados que a tabela recusa viram conflito (FA990).
  - Viram alerta da venda: controlado sem os dados, liberado por quem não tinha a permissão, pendente, receita vencida ou futura, tipo de receita diferente do da lista.
- **Retaguarda:** `/controlados` lista por situação (todas, pendentes, completas) e período, com o documento do comprador mascarado. Exige `controlled.view` (Farmacêutico e Gerente).
- **Dados pessoais:** vão só pela outbox e ficam no banco local criptografado e na central. Não entram no log nem no comprovante (que mostra lote, receita e farmacêutico).
- **Seed:** Clonazepam de demonstração (lista B1, código de barras 7890000000055) com o lote CLZ01 na Loja Centro. O Administrador (PIN 2580) pode liberar.

**NFC-e: motor fiscal no PDV (Etapa 8, 8A-1)**

- **Onde:** `apps/pdv/lib/fiscal/`. Monta a NFC-e (modelo 65, leiaute 4.00) a partir da venda, dos dados fiscais da filial (`fiscal`) e da tributação do produto que desce do catálogo; assina; gera o QR Code. A emissão no caixa (transmissão, contingência e DANFE) é do 8A-2.
- **Tributação atendida:** Simples (CSOSN 102, 103, 300, 400 e 500) e regime normal (CST 00, 20, 40, 41, 50 e 60); PIS e COFINS com alíquota, não tributados e outras. O resto (ST na operação, crédito do Simples etc.) dá FA723. Filial sem dado fiscal: FA724; UF fora das atendidas: FA725.
- **Reforma tributária:** o grupo IBS/CBS (`IBSCBS` no item e `IBSCBSTot`) é montado só com `ibsCbs` ligado, por empresa, quando o contador confirmar.
- **Homologação:** o primeiro item sai com "NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL" e o destinatário com o texto curto exigido.
- **Assinatura:** XMLDSig envelopada (RSA-SHA1, C14N inclusiva) com a chave e o certificado que virão da central (o PDV não lê .pfx). `xml_c14n.dart` canonicaliza o que a NF-e usa.
- **QR Code:** versão 2 (com o CSC), online e em contingência. A versão 3 (sem CSC no online) fica para depois de conferir a NT 2025.001 oficial: o formato da assinatura da contingência v3 não está publicado fora dela.
- **Endereços por UF** (`nfce_urls.dart`): SP, PR, RS, SC e MG, homologação e produção. **Conferir no portal de cada UF antes de produção** (endereço errado é rejeição 395).
- **Testes** (`test/nfce_test.dart`):
  - o XML é validado contra os **schemas oficiais PL_010h v1.03** (em `test/fixtures/schemas`) pelo .NET do PowerShell (`tool/validate-xsd.ps1`), sem instalar nada;
  - a assinatura de uma nota de referência é conferida **por outra implementação**, a `xml-crypto` da API (`apps/api/src/fiscal/nfce-signature.spec.ts`). A nota de referência é regravada com `UPDATE_NFCE_FIXTURE=1`;
  - o certificado e a chave dos testes são autoassinados e só de teste.

**NFC-e: certificado no caixa (Etapa 8, 8A-2a)**

- **Emitir NFC-e por filial** (tela Fiscal, permissão `fiscal.manage`; `app.set_branch_nfce`): ligado ou não, ambiente (homologação por padrão, ou produção) e prazo da contingência (1 a 168 horas, padrão 24; o caixa avisa na metade). Para ligar: estado atendido (FA725), inscrição estadual, regime e CSC (FA727) e certificado dentro da validade (FA943). Valores fora disso: FA728. Desligar não pede nada.
- **Chave do caixa:** cada caixa cria uma chave X25519 só para receber o certificado (guardada como a chave do terminal) e a registra em `POST /terminals/nfce/key`, assinada pela chave Ed25519 do terminal (`farmaerp-terminal-fiscal-key:{terminal}:{chave}`). Assinatura que não confere: FA731.
- **Entrega** (`POST /terminals/nfce/credentials`, `app.terminal_nfce_credentials`): só para caixa ou autoatendimento (FA729) de filial com a NFC-e ligada (FA730). A API abre o .pfx e o CSC só durante a chamada e devolve chave privada (PKCS#8), certificado do titular e CSC cifrados para aquele caixa: X25519 com chave temporária, HKDF-SHA256 e AES-256-GCM, com o terminal e a versão autenticados junto. Cada entrega fica em `terminal_credential_delivery` (sem o conteúdo).
- **Troca:** certificado ou CSC novo muda a `credential_version` que desce nos dados fiscais (`nfce`); o caixa busca de novo na sincronização seguinte. Filial desligada: o caixa apaga o que guardou.
- **No PDV** (`lib/fiscal/nfce_credentials.dart`): a entrega fica no banco local como chegou, ainda cifrada (tabela `nfce_credential`), e só é aberta em memória para emitir. A barra inferior mostra "NFC-e: aguardando o certificado", "pronta" ou "certificado vencido". Entrega que não abre: FA732.
- **Tela Fiscal:** o que falta para ligar e quantos caixas já receberam o certificado em uso.
- **Testes:** a entrega de referência (`apps/pdv/test/fixtures/fiscal/entrega-certificado.json`, chave e certificado só de teste) é gerada com o código da API e aberta tanto pelo PDV (Dart) quanto pela API.

**Cliente cadastrado no caixa**

- Na janela de cliente do PDV (F4), "Cadastrar cliente" abre o cadastro: nome, CPF, telefone e nascimento (opcionais), e os consentimentos de cashback e de ofertas (opcionais, registrados como dados na loja). O CPF ou o nome digitados na busca já vêm preenchidos.
- Só com internet (`POST /terminals/customers`, `app.pdv_create_customer`, migration 0058): a central confere o CPF repetido na hora (FA901, com o atalho "Buscar o cliente por este CPF"). Sem internet: FA984, e a venda segue sem cliente.
- Quem cadastra é o operador do caixa, conferido pela permissão de vender na filial do terminal. O cliente novo já fica guardado no terminal e escolhido na venda.

**Histórico de compras do cliente**

- Ticket médio dos últimos 12 meses (com o total e o número de compras), compras dos últimos 30 dias (data, venda, loja, itens e total) e produtos recorrentes (em 2 ou mais compras nos últimos 180 dias). Migration 0059.
- **Retaguarda:** seção "Compras" na ficha do cliente (`GET /admin/customers/:id/history`), só com as filiais que o usuário vê; exige `customers.view` ou `customers.manage`.
- **Caixa:** botão de histórico no painel do cliente da venda (`GET /terminals/customers/:id/history`), com a rede inteira do grupo. Só com internet (FA984 sem conexão).

**Importação das notas do sistema anterior (I1: NFC-e)**

- **Envio:** `POST /admin/imports` (nome e tamanho, .zip até 1 GB), `PUT /admin/imports/:id/parts/:n` (partes de até 20 MB, em ordem) e `POST /admin/imports/:id/complete`. Permissão `imports.manage` (Administrador). O arquivo fica em `IMPORTS_DIR` (ou no volume `/data/imports`) até ser processado (FA740 sem a pasta; FA741 parte fora de ordem).
- **Processamento** (`ImportsService`, a cada 10 s): lê o .zip entrada por entrada (`yauzl`), cada XML vira uma chamada a `app.import_nfce` (uma transação por nota) e os cancelamentos (evento 110111 homologado) ficam para o fim. Reprocessar é seguro: nota repetida é ignorada pela chave.
- **Regras (migration 0061):** só NFC-e de produção autorizada (100/150); homologação e sem protocolo são ignoradas; NF-e 55 e outros documentos são contados para as próximas etapas.
  - **Filial** do emitente pelo CNPJ (criada com a empresa, se a raiz for nova; CNPJ de outro cliente: FA742).
  - **Produto** pelo código do sistema anterior (`product.legacy_code`): criado com o nome, GTIN válido e livre (senão o próprio código como código interno), NCM e CEST próprios (`own_ncm`, `own_cest`) e o preço da nota.
  - **Tributação própria** (`product_tax_rule`, por regime e UF): CFOP, origem, CST/CSOSN, alíquotas e cBenef da nota mais recente.
  - **Cliente** pelo CPF/CNPJ do destinatário (sem nome: "Cliente CPF ***.***.***-NN").
  - **Venda importada** (`imported_sale`, itens e pagamentos, com o XML) e **saída de estoque** do tipo `import` na data da nota, que pode deixar o saldo negativo e **não entra no SNGPC**. Cancelamento desfaz a venda e devolve o estoque.
  - Nota com problema fica no relatório (FA743), com o motivo; as outras seguem.
- **Relatório** (`GET /admin/imports/:id`): situação, contagens por modelo e resultado, problemas e a última numeração por filial, modelo e série.
- **Tela** `/importacoes` (permissão `imports.manage`): envio do .zip em partes de 8 MB pela retaguarda (rota `/importacoes/envio/:id/:parte`, que recusa parte cortada pelo limite de 10 MB do proxy do Next), lista dos arquivos e relatório que se atualiza sozinho enquanto processa.
- **Vendas importadas (I2b, migration 0062):** `GET /admin/imported-sales` (filial, período e cliente), `/:id` (itens com o código anterior e pagamentos) e `/:id/xml`, com `sales.view` na filial. Telas `/vendas-importadas` e o detalhe; o histórico do cliente (retaguarda e PDV) soma as importadas não canceladas, com o número da nota no lugar do código da venda.
- **Tributação própria no caixa (I2c, migration 0063):** sem os dados no Catálogo, o produto desce com o NCM/CEST próprios e a regra própria (`product_tax_rule`) do regime e da UF da filial, no mesmo formato da tributação do Catálogo (`own: true`). Regra sem PIS/COFINS não desce. Mudar a regra faz o produto descer de novo; os produtos já importados descem de novo na publicação.
- **NF-e 55 (I3a, migration 0064):** o arquivo é lido em duas passadas (NFC-e primeiro, que cadastram as filiais; NF-e depois). A direção sai do CNPJ: filial do cliente no emitente, no destinatário ou nos dois.
  - **Recebida:** compra (`imported_stock_note` kind `purchase`) entra no estoque com fornecedor pelo CNPJ; produto pelo vínculo código do fornecedor, depois GTIN (do item ou da unidade tributável), senão criado; o vínculo é gravado e o fracionamento dele vale. Devolução de cliente e outras entradas também somam.
  - **Emitida:** pelo CFOP (`app.import_cfop_kind`): venda vira venda importada (modelo 55, cliente pelo destinatário); devolução ao fornecedor e outras saídas baixam; transferência entre filiais sai de uma e entra na outra (filial nova da mesma raiz é cadastrada); entrada emitida pelo cliente (tpNF 0) soma.
  - **Custo:** o da compra importada mais recente por produto e filial (`product_cost.imported_stock_item_id`), só nos itens de CFOP de venda (bonificação entra sem custo). Compra lançada no próprio sistema manda. Cancelamento estorna o custo se ele ainda for o vigente.
  - Lotes ficam no item (sem saldo por lote) e nada entra no SNGPC. Nota sem filial do cliente, entrada emitida por terceiro, homologação ou sem autorização: ignorada, e o relatório conta as ignoradas por motivo.
- **Notas importadas (I3b, migration 0065):** `GET /admin/imported-notes` (filial, que inclui a que recebeu a transferência, período e natureza), `/:id` (itens com o código do fornecedor, quantidade da nota e do estoque, custo e lotes) e `/:id/xml`, para quem tem `stock.view` ou `purchases.view` numa das filiais da nota. Tela `/notas-importadas` e o detalhe.

**Inventário de abertura (E1, migration 0066)**

- Inventário por filial com data e hora de corte (`stock_count` e `stock_count_item`), permissão `stock.opening` (Administrador). Um em contagem por filial (FA744); corte no futuro ou antes de outro aplicado: FA747.
- **Contagem:** planilha CSV (`POST /admin/stock-counts/:id/file`, texto; cada arquivo soma, para contar por seção) e digitação (`PUT /admin/stock-counts/:id/items`, define a quantidade). Código de barras, interno ou do sistema anterior; cabeçalho opcional (Código, Quantidade, Lote, Validade), ";" ou ",", número 1.234,5 e validade dd/mm/aaaa ou mm/aaaa. Linha com problema volta com o motivo, sem parar as outras.
- **Lote:** produto que exige lote é contado por lote, com validade (FA746); nos outros, o lote é ignorado.
- **Conferência** (`app.stock_count_review`): saldo no corte (só movimentos até ele: o caixa continua vendendo), contado e diferença; lote existente com outra validade aparece como problema e impede aplicar.
- **Aplicar** (`app.apply_stock_count`): o contado vira o saldo; o que tinha saldo e não foi contado vai a zero (inclusive o saldo antigo sem lote de produto que exige lote). Cada diferença é um movimento `inventory` na hora do corte, ligado ao inventário, que pode deixar o saldo negativo (venda depois do corte) e não entra no SNGPC. Sem custo. Aplicado ou cancelado não muda (FA745).
- Tela `/inventario` e o detalhe (contar, conferência, linhas contadas, aplicar e desistir).

**NFC-e pela central (8A-3a, migration 0067)**

- Cliente da NFC-e por UF na API (`apps/api/src/sefaz/nfce-sefaz.ts`): consulta (NFeConsultaProtocolo4), autorização (reenvio da nota que o caixa assinou), evento de cancelamento 110111 e inutilização, com o certificado da filial no TLS. A central só fala com o ambiente da Sefaz que é o dela. Testes com Sefaz falsa (`SEFAZ_NFCE_URL` + `SEFAZ_TEST_CA`, só fora da produção). Endereços por UF a conferir antes de produção.
- **Reenvio automático** (`NfceActionsService`, de hora em hora; `FISCAL_WORKER=off` desliga): `app.claim_fiscal_resend` reserva até 30 notas por grupo por hora, das em contingência ou pendentes que passaram da metade do prazo da filial. A nota tentada fica marcada; consulta antes de enviar (não duplica); recusada de novo vira aviso e não volta ao lote (só pelo botão); sem Sefaz, tenta na hora seguinte. O caixa retransmitindo nota que a central já resolveu é ignorado, sem travar a fila.
- **Cancelamento** (`fiscal.cancel`): só a autorizada e até 30 minutos (FA748). A venda é desfeita junto (`app.cancel_sale_effects`): estoque por estorno (fora do SNGPC, onde a saída é desconsiderada), dispensação, cashback ganho estornado (o que sobra do lote) e usado liberado, crediário quitado por recebimento "cancel", pagamentos fora do caixa, do convênio e do crédito de devolução, orçamento reaberto; turno fechado: a devolução do dinheiro sai do turno aberto do terminal. Bloqueia venda com devolução (FA749), convênio faturado (FA750), controlado conferido no SNGPC (FA751) e crediário pago (FA752). Cancelada na Sefaz por fora (vista na consulta) com bloqueio ou fora do prazo: a nota fica cancelada, a venda fica e vira aviso.
- **Inutilização** (`fiscal.void`): `app.fiscal_number_gaps` sugere os buracos por série e terminal (inclui rejeitadas; "seguro" quando o caixa não tem nada na fila); a faixa é conferida (FA755) e registrada com o protocolo.
- API `/admin/fiscal-documents`: lista (filtros e avisos), `/gaps`, `/voids`, `/:id/xml` (e `?kind=cancel`), `/:id/consult`, `/:id/resend`, `/:id/cancel`, `/:id/dismiss`. O cancelamento no caixa (8A-3c) pede à central: `POST /terminals/fiscal-documents/:id/cancel` (reason, supervisorId), com as funções `app.terminal_cancel_context` e `app.terminal_cancel_register` (migration 0069): nota do próprio terminal, supervisor ativo do grupo com `fiscal.cancel` na filial (o PIN é conferido no caixa), mesmo prazo e bloqueios; pedido repetido responde `already` sem chamar a Sefaz. Autorização: só o 204 é "a mesma nota já está lá" (consultar); o 539 (mesmo número, outra chave) é recusa e vira aviso.
- **No caixa (8A-3c2, banco local v18):** botão "Cancelar venda" na última venda, até 30 minutos da autorização, com internet: motivo (15 a 255) e supervisor com "Cancelar NFC-e" (outra pessoa, PIN conferido no caixa). Antes, a fila sobe (a venda precisa estar na central: FA756); sem resposta, o caixa avisa que pode ter sido feito e repetir é seguro. A retransmissão consulta a Sefaz antes de enviar (autorizada pega o protocolo, cancelada fica cancelada, só envia a que a Sefaz não tem) e o 204 consulta para pegar o protocolo.
- **Correções (migration 0068):** o lote do reenvio pega primeiro as notas nunca tentadas; falha que não se resolve sozinha (sem certificado FA943, UF não atendida FA754, ambiente diferente FA753) e seis rodadas sem a Sefaz viram aviso e saem do lote. O resultado do reenvio (`app.fiscal_resend_result_checked`) e o cancelamento (`app.fiscal_cancel_register`, `fiscal.cancel`; `app.fiscal_consult_canceled` para a nota cancelada por fora) conferem quem pede; os núcleos ficam internos. Recusa da Sefaz volta com o código e o motivo em `detail`.
- **Tela `/notas-fiscais` (8A-3b):** avisos (recusadas, sem certificado, canceladas por fora sem desfazer a venda), lista com filtros, consultar, reenviar (`fiscal.void`), cancelar com motivo de 15 a 255 letras e contagem do prazo (`fiscal.cancel`), XML da nota e do cancelamento; `/notas-fiscais/inutilizacao` com as faixas sugeridas (as que o caixa ainda pode usar pedem confirmação) e o histórico. Sem resposta da API a tempo, a tela orienta a consultar antes de repetir.

**Descartar a venda e cadastros no PDV (parte A do lote de 26/11, migration 0070)**

- **Permissões novas:** `pdv.quote_clear` (limpar a tela do orçamento), `pdv.sale_cancel` (cancelar a venda em andamento no caixa), `pdv.self_service_cancel` (no autoatendimento), `pdv.customer_create` e `pdv.prescriber_create` (cadastros no caixa). Perfis padrão: Gerente e Farmacêutico todas; Operador de caixa limpar orçamento e os dois cadastros; Balconista limpar orçamento e cadastrar cliente. Os perfis que já existiam recebem o mesmo pela migration.
- **Venda descartada** (`pdv_cart_discard`, só sobe do terminal, tipo `cart_discard` da outbox): tela, quem estava, quem liberou, itens, total e hora. Quem respondeu sem a permissão da tela (na filial do terminal) fica com o alerta `release_permission`.
- **Cadastros:** cliente no PDV passa a exigir `pdv.customer_create` (antes, `sales.sell`); prescritor que sobe com `created_by` exige `pdv.prescriber_create` na filial (FA002); caixas antigos, sem `created_by`, seguem aceitos.
- **No caixa:** botão "Limpar tela" (orçamento) ou "Cancelar venda" (caixa e autoatendimento) com itens na tela, também durante o pagamento. Quem não tem a permissão da tela chama o supervisor (código e PIN, outra pessoa, com a permissão: FA757/FA982) no mesmo diálogo (`ReleaseDialog`); o descarte limpa itens, cliente e pagamentos, devolve a reserva de cashback e sobe como `cart_discard`. "Cadastrar cliente" e "Cadastrar prescritor" sem a permissão pedem a liberação antes; o cadastro vai em nome de quem liberou. O cancelamento da NFC-e da última venda passa a se chamar "Cancelar última venda". Cards com sombra mais forte e contorno (tema do PDV).

**Profissionais da saúde (prescritores)**

- **Cadastro** (`health_professional`, migration 0057, por grupo): nome, conselho (CRM, CRO, CRMV, COREN, CRF, RMS), número, UF, especialidade (opcional) e situação. O mesmo conselho, número (sem zeros à esquerda, sem diferença de maiúsculas) e UF não se repete (FA733); dados inválidos: FA734.
- **Retaguarda:** `/profissionais`, com busca por nome ou número, cadastro, edição e inativação. Cadastra quem tem `health_professionals.manage` (Gerente e Farmacêutico); quem tem `controlled.view` só consulta.
- **Caixa:** os ativos descem para todos os caixas do grupo (7º tipo da descida; formato 8, que faz os caixas recarregarem tudo uma vez). Inativo desce vazio e sai da cópia local. O cadastro rápido feito no caixa sobe pela outbox (`health_professional`); se a central já tiver o mesmo profissional, fica com o que já tinha, sem conflito.
- A receita da venda continua guardando o prescritor por extenso: o cadastro só ajuda a preencher.

**NFC-e: emissão no caixa (Etapa 8, 8A-2b1)**

- **Na finalização** (filial com "Emitir NFC-e" e o certificado no caixa): a venda é gravada; depois o PDV monta a NFC-e com a série do caixa (modelo 65; próximo número depois do maior entre o inicial, o que a central conhece e o que o caixa já usou), assina e transmite direto à Sefaz da UF (`lib/fiscal/sefaz.dart`, NFeAutorizacao4, lote síncrono, certificado do caixa no TLS, 15 s).
  - **Autorizada:** guarda o `nfeProc` (nota + protocolo) e imprime o **DANFE NFC-e** com número, série, protocolo, consulta pela chave e o **QR Code** (ESC/POS e PDF). Em homologação, "EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO / SEM VALOR FISCAL".
  - **Recusada** (FA736): a venda conclui com a nota pendente e o comprovante comum; a nota assinada fica guardada com o motivo.
  - **Sem resposta da Sefaz** (8A-2b2): a nota sai em **contingência offline** (tpEmis 9, mesmo número, outra chave, com a hora e o motivo) e o caixa imprime o DANFE com "EMITIDA EM CONTINGÊNCIA / Pendente de autorização" e o QR Code (FA739). Se nem a contingência puder ser montada, fica pendente (FA737).
  - **Retransmissão:** depois de cada sincronização (com internet), o caixa transmite as notas em contingência e as pendentes, das mais antigas para as mais novas; para na primeira sem resposta. Autorizada ou recusada, a nota sobe de novo pela outbox com o mesmo id e a central atualiza a situação.
  - **Prazo:** a barra do caixa mostra as notas em contingência; com metade do prazo da filial (padrão 24 h, aviso com 12 h) o aviso fica em negrito; vencido o prazo, em vermelho, pedindo para conferir a internet.
  - **Sem certificado no caixa** (FA738) ou **produto sem NCM/tributação** (FA726/FA723): a venda conclui sem nota e o número não é gasto.
- **Na central** (migration 0060, `fiscal_document`): a nota sobe pela outbox depois da venda (item `nfce`); a venda passa a mostrar a situação fiscal (autorizada, recusada, pendente, contingência) e a série do terminal anda. Nota autorizada não muda (FA735). Retaguarda: detalhe da venda com série, número, chave, protocolo, motivo da Sefaz e "Baixar o XML".
- **Endereços da Sefaz** por UF (SP, PR, SVRS para RS e SC, MG): **conferir antes de produção**. No primeiro envio real, conferir também a cadeia de certificados da Sefaz (raízes da ICP-Brasil).
- **Testes:** Sefaz falsa (respostas no formato do manual: autorizada, recusada, lote recusado, serviço parado, sem conexão); venda completa com a nota validada no schema oficial.

**SNGPC: manutenção (Etapa 8, entreposto)**

- **Abertura por filial** (`app.sngpc_open`, permissão `sngpc.manage`, do Farmacêutico): o saldo de cada lote de controlado vira o inventário inicial. Saldo sem lote ou negativo fica fora e aparece no aviso, para acertar o estoque. Já aberto: FA861; ainda não aberto: FA862.
- **Movimentações** (`sngpc_movement`): depois de aberto, toda movimentação de estoque de produto controlado entra pendente, por trigger: entrada por compra, transferência ou devolução, venda (ligada à dispensação), perda, transferência enviada e ajustes. A quantidade é sempre positiva; o tipo diz se entra ou sai. Nada é enviado sozinho.
- **O que o farmacêutico completa** na pendência:
  - data no SNGPC (não no futuro; FA866);
  - motivo da perda (furto, avaria, vencimento, apreensão, amostra, recolhimento, outro);
  - lote, quando a movimentação veio sem;
  - quantidade contada, no inventário;
  - lote e receita da venda liberada como pendente no caixa (`sngpc_dispensing_complement`; a dispensação original não muda; receita da data da venda ou antes, dentro da validade, FA987; só venda pendente, FA867).
  - Inventário e ajustes podem ficar fora do SNGPC, com motivo (FA868, FA302): o SNGPC não tem ajuste de entrada.
- **Simulação** (`app.sngpc_check`): para as escolhidas, aponta o que falta e o saldo por lote, com as já conferidas mais as escolhidas, na ordem do SNGPC (data, inventário, entradas antes das saídas, hora):
  - inventário da filial ainda não conferido;
  - pendência anterior do mesmo produto (segura as posteriores);
  - sem lote, lote sem MS, venda sem receita, perda sem motivo, ajuste de entrada;
  - data no futuro ou antes da abertura (sugere a data);
  - saída antes da entrada do lote (sugere a data da entrada) ou saldo do lote negativo.
- **Conferência** (`app.sngpc_confirm`): a API pede a senha de quem confere (FA409); tudo ou nada (FA864 com o que falta); data de envio de hoje em diante. Grava quem, quando e o MS do lote. Conferida não muda mais (FA863), e só segue o caminho do envio (enviada, aceita ou recusada), que chega no 8C-2.
- **Retaguarda:** `/sngpc` com as filiais, o aviso de inventário, de pendência com mais de 7 dias e de envio com data chegada; as abas "Pendentes" (escolher, corrigir, simular e conferir), "Conferidas" e "Fora do SNGPC". O comprador aparece mascarado.
- **Erros:** FA861 a FA868.

**SNGPC: envio à Anvisa (Etapa 8)**

- **Credencial do SNGPC por filial** (usuário e senha do farmacêutico responsável): em `/sngpc`, criptografada pela API com `FISCAL_ENCRYPTION_KEY` (`sngpc_credential`). A tela mostra só a data do cadastro.
- **Remessas** (`sngpc_submission`): a rotina da API (`SngpcService`, a cada minuto, `app.worker = 'sngpc'`) pega as filiais com credencial e com o que fazer, reservando cada uma por 10 minutos (várias instâncias não repetem).
  - A primeira remessa da filial é o **inventário**; as movimentações só saem depois do inventário aceito.
  - Entram as conferidas com a data de envio chegada, na ordem do SNGPC. Produto com movimentação recusada fica de fora até ela ser corrigida e conferida de novo.
  - Uma remessa em aberto por filial. O **arquivo é guardado como foi enviado** (com o SHA-256 e o protocolo) e não muda (FA720).
  - Falha de transmissão fica registrada na remessa (tentativas e o último erro) e a rotina tenta de novo; credencial recusada aparece como FA722.
  - **Resultado:** aceita, ou recusada com o motivo da Anvisa. A recusa volta para o farmacêutico (aba "Recusadas", "Reabrir para corrigir").
- **Arquivo e conector provisórios:** `apps/api/src/sngpc/sngpc-xml.ts` segue a estrutura do SNGPC atual e `sngpc-gateway.ts` usa um contrato próprio (o da Anvisa falsa dos testes). Antes de ligar o envio real, conferir os dois com a documentação oficial da API nova da Anvisa. Os códigos dos motivos de perda ficam em `app.sngpc_loss_code`.
- **Envio real desligado por padrão:** só liga com `SNGPC_LIVE=true` e `SNGPC_URL` (HTTPS fora do desenvolvimento). Desligado, as remessas ficam montadas esperando, e a tela avisa. `SNGPC_WORKER=off` desliga a rotina (testes).
- **Retaguarda:** abas "Aceitas", "Recusadas" e "Envios" (remessas, situação, protocolo, tentativas e o arquivo para baixar); avisos de credencial que falta, envio desligado, data de envio passada e recusas.
- **Erros:** FA720 a FA722 (faixa `FA72x` reservada para a Etapa 8).

## Clientes

- **Cadastro:** único na rede, com código humano. Pessoa física com CPF ou jurídica com CNPJ, ambos com dígito validado e sem repetir no grupo. Só nome e documento são obrigatórios.
- **Dados pessoais:** mensagens e detalhes de erro do banco levam só identificadores. A API descarta o detalhe do Postgres no log, que traria o valor da chave. A lista mostra o documento mascarado, e a ficha mostra completo.
- **Consentimento:** cada concessão ou revogação é uma linha que nunca muda. A mais recente vale. Repetir a decisão atual não gera registro.
- **Reconhecimento facial:** só a decisão é registrada. O sistema não guarda imagem nem biometria.
- **Consulta de CNPJ:** em cascata, BrasilAPI, ReceitaWS e CNPJá, com 5 segundos por serviço. Só preenche a tela, e a pessoa confere antes de salvar. Os serviços devolvem também os sócios, e isso nunca é repassado nem gravado em log.
- **Inscrição estadual:** confere o tamanho esperado em cada estado, ou ISENTO. O dígito verificador entra com o Fiscal.
- **Convênios:** cadastro e vínculo com matrícula e limite, com `agreements.manage` em todas as filiais, porque o limite é crédito da rede. Faturas: veja "Fatura do convênio".
- **Exclusão a pedido do titular:** ainda não existe. A proposta é anonimizar, mantendo só o que a lei fiscal exige.

## Fornecedores

Base da entrada de nota: o código que vem no XML aponta o produto e o fracionamento da compra.

- **Cadastro:** único na rede, por CNPJ completo, com a mesma consulta pública de CNPJ dos clientes. O CNPJ não muda depois do cadastro, porque as notas ficam ligadas a ele.
- **Inscrição estadual:** conferida pelo dígito do estado, então estado e inscrição andam juntos. ISENTO é aceito.
- **Código do fornecedor:** o `cProd` da nota, com até 60 caracteres. Um código aponta um só produto, e o produto pode ter vários códigos e vários fornecedores. Trocar o código é remover e ligar de novo.
- **Fracionamento:** três níveis, do mais específico ao mais geral: relação com o fornecedor, código de barras e produto. `app.effective_fraction(produto, código de barras, relação)` resolve.
- **Encerrar o fornecedor:** encerra também os códigos dele.
- **Permissões:** `purchases.view` vê, e `purchases.manage` cadastra e liga códigos, valendo para a rede. O Gerente recebe as duas, porque recebe a nota da loja.

## Notas de compra

Importação, conferência e lançamento da NF-e de compra no estoque.

- **Envio:** em `/notas`, um ou vários XML, até 20 por vez e 5 MB cada. Cada arquivo vai numa requisição própria, como `application/xml`, e tem o seu resultado na tela.
- **Conferência do XML, na API:** só a nota autorizada com protocolo (`nfeProc`, modelo 55, situação 100 ou 150). Confere o dígito da chave e se ela bate com a nota; a assinatura, com o certificado do próprio XML; e se o `digVal` do protocolo é o resumo assinado. Os dados saem só do trecho que a assinatura cobre. DOCTYPE é recusado. O motivo técnico de uma recusa fica só no log.
- **Limite da conferência:** a assinatura prova que o XML não foi alterado, mas não que o certificado é ICP-Brasil, e o protocolo dentro do XML não é assinado. Por isso, em produção, a nota só se lança depois de confirmada pela Sefaz (veja abaixo).
- **Regras, no banco:**
    - A filial é a do CNPJ do destinatário.
    - O fornecedor é criado pelo emitente quando ainda não existe.
    - A mesma chave não entra duas vezes no grupo.
    - A produção recusa nota de teste da Sefaz.
    - Devolução, complementar, ajuste, nota de entrada e nota emitida por filial da rede ficam registradas, mas não vão para o estoque.
- **Ligação dos itens:**
    1. Código do fornecedor.
    2. Código de barras (`cEAN`), criando a relação com o fornecedor.
    3. Ligação manual, que acrescenta o código de barras ao produto quando ele não é de outro.
    4. Duplicar um produto parecido ou cadastrar pelo Catálogo.
- **Trocar produto:** move o código do fornecedor para o produto novo. Os itens iguais de outras notas em conferência seguem junto.
- **Descartar:** é a exclusão lógica, com motivo. Libera a chave para importar de novo, e o XML continua guardado.
- **Permissões:** a nota é da filial. Importar e conferir exige `purchases.manage` na filial do destinatário, e ver exige `purchases.view`. Duplicar ou cadastrar produto exige também `products.manage`.

### Lançamento

- **Tudo ou nada:** `app.post_purchase_invoice` lança a nota inteira numa transação. Qualquer pendência barra o lançamento, e a tela lista o que falta antes do clique.
- **Estoque:** cada item entra como movimentação `invoice` ligada ao item da nota, na quantidade da nota vezes o fracionamento (relação com o fornecedor > código de barras > produto).
- **Custo unitário:** (produtos − desconto + frete + seguro + outras + IPI + ST + FCP-ST) ÷ quantidade no estoque. Créditos de imposto não são descontados, e bonificação entra pelo valor líquido.
- **Custo médio por filial:** média móvel sobre o saldo da filial, em `product_cost` (só inclusão; a última linha vale). Sem custo anterior ou com saldo zerado ou negativo, vale o custo da entrada. Duas notas do mesmo produto e filial ao mesmo tempo esperam uma pela outra.
- **Trava de custo:** usa a regra `cost_tolerance` do motor de regras. Acima da tolerância, a linha trava até alguém com `purchases.cost_override` liberar com a própria senha e um motivo. A liberação vale só para aquele produto e aquele custo. Sem regra, ou na primeira entrada, não trava; sem regra, a tela só avisa.
- **Lotes:** os do XML, ou digitados na conferência, na unidade da nota. A soma precisa fechar com o item, e lote vencido barra o lançamento. Os lotes do XML ficam guardados quando são trocados. O MS da nota vale só para lote novo. Produto que não controla lote na filial ignora os lotes da nota.
- **PMC:** o da nota é gravado para o estado e a região da filial, com origem `invoice`. Igual ao vigente não gera linha.
- **Estorno:** movimentações contrárias, com motivo, e o custo médio pela conta inversa. Sem saldo depois, ou com a conta dando negativa, volta o custo de antes da entrada. Se parte do que entrou já saiu, o banco recusa. A nota volta para a conferência e as liberações de custo caem. O PMC gravado fica.
- **Histórico:** quem lançou e quem estornou ficam em `purchase_invoice_event`. Nota lançada não se confere nem se descarta.
- **Permissões:** `purchases.post` lança e estorna (o Gerente tem). `purchases.cost_override` libera custo (só o Administrador, por padrão). O custo médio aparece no produto para quem tem `purchases.view` ou `purchases.manage` na filial.

### Download automático e confirmação pela Sefaz

- **Distribuição (NFeDistribuicaoDFe, Ambiente Nacional):** a rotina da API roda a cada minuto e busca, por NSU, as filiais com o download ligado em `/fiscal` e com certificado A1 válido. Respeita a espera de uma hora depois de "nada novo" (137) ou de "consumo indevido" (656). Cada filial fica reservada por 10 minutos durante a busca, então várias instâncias da API não repetem consulta.
- **O que chega:** cada documento fica guardado em `dfe_document`, uma vez por NSU. O resumo (`resNFe`) vira uma nota "Aguardando ciência" em `/notas`; o XML completo (`procNFe`) passa pela mesma conferência da importação manual e entra confirmado; o evento de cancelamento (110111) cancela a nota.
- **Ciência da operação (210210):** só por clique, uma nota por vez, por quem tem `purchases.manage` na filial. O evento vai assinado com o certificado da filial, e o XML completo chega pela consulta da chave nos minutos seguintes.
- **Confirmação:** a nota importada à mão é comparada com o resumo da Sefaz pelo resumo da assinatura (`digVal`). Sem resumo, a rotina consulta a chave (até 15 consultas por hora por filial). Em produção, a nota só se lança confirmada; fora dela, a confirmação só aparece na tela.
- **Cancelamento:** nota em conferência passa a "Cancelada pelo emitente" e não se lança; nota já lançada ganha um alerta, e o estorno fica a critério de quem confere.
- **Ambiente da Sefaz:** a API de produção usa a Sefaz de produção; homologação e desenvolvimento usam a homologação da Sefaz, para nenhuma ciência oficial sair de lá.
- **Funções da rotina:** as `app.dfe_*` só respondem com `app.worker = 'dfe'` e sem usuário na sessão. Os testes usam uma Sefaz falsa (`SEFAZ_DIST_URL`, `SEFAZ_EVENT_URL` e `SEFAZ_TEST_CA`, ignoradas em produção) e desligam a rotina com `DFE_WORKER=off`.
- **Fora por enquanto:** notas com mais de 90 dias (a distribuição não as entrega; a consulta por UF fica para depois) e as manifestações conclusivas (confirmação, desconhecimento e operação não realizada).

### Notas de serviço (NFS-e)

- **Origem:** a API de distribuição do Ambiente de Dados Nacional (`GET /contribuintes/DFe/{NSU}?cnpjConsulta=...&lote=true`), com o mesmo certificado A1 e a mesma chave "Download automático" da filial. Desde 2026 os municípios aderem ao padrão nacional, então o ADN entrega as notas de qualquer município.
- **Ritmo:** lotes de até 50 documentos, um segundo entre chamadas, e uma hora de espera quando não há nada novo ou quando dá erro. A NFS-e tem NSU próprio, guardado em `branch_dfe_sync` ao lado do da NF-e.
- **O que chega:** cada documento fica em `dfe_document` (origem `nfse`). A nota vira uma linha em `service_invoice`, com prestador, competência, serviço, ISS, retenções federais e valor líquido. O cancelamento (101101) marca "Cancelada pelo prestador"; a substituição (105102, ou a nota nova com `chSubstda`) marca a antiga como "Substituída" e liga à nova, em qualquer ordem de chegada.
- **Leitura:** segue o modelo da NFS-e autorizada publicado pela Receita Federal (`NFSe/infNFSe`, com a DPS dentro). Só chave, número, emissão, competência, prestador, descrição, valor do serviço e valor líquido são obrigatórios; o resto fica vazio se vier fora do formato.
- **Tela:** `/notas-servico` lista as notas em que a filial é tomadora, por competência e situação, com o total das válidas. O detalhe mostra os valores e baixa o XML original. As notas emitidas pela própria filial ficam guardadas, fora da tela, até a etapa de emissão de NFS-e.
- **Só registro:** a nota de serviço não mexe em estoque nem em custo. Fica pronta para o contas a pagar.
- **Testes:** um ADN falso em HTTPS (`SEFAZ_ADN_URL`, ignorada em produção).
