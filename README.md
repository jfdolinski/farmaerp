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
- **Primeiro tipo, os logs:** avisos e erros do PDV (nunca `info`), já sem dados pessoais, vão para `terminal_log` com o rastreio da operação. Até 5.000 esperam envio; acima disso ficam só no arquivo local. Logs entregues saem da fila local depois de 7 dias.
- **Tipos novos:** cada tipo ganha uma procedure no banco, chamada pelo `CASE` de `app.pdv_push`. Tipo desconhecido vira conflito (FA959).

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
  - **Cadastro:** no ícone de rosto da barra de cima. Quem autoriza digita o código e o PIN e precisa de "Cadastrar o rosto e a digital no PDV" (`users.biometrics`, perfil Gerente; FA822). Depois vêm o código da pessoa, o termo de consentimento (versão `biometria-v1`) e a leitura com 5 quadros. O cadastro vale na hora no terminal e sobe pela outbox (`face_enrollment`) com o consentimento (`biometric_consent`).
  - **O que é guardado:** só o código numérico do rosto (128 números, 512 bytes, `face_template`), nunca a imagem. Os quadros da câmera ficam só na memória. O código desce para os PDVs das filiais da pessoa e fica no banco local criptografado. A aplicação não lê as tabelas do rosto; a retaguarda vê só a situação (`app.face_enrollments`).
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
  - O pagamento em convênio aparece só com cliente que tenha convênio, com a matrícula. O saldo do convênio chega com o financeiro do cliente (Etapa 7).

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
    - abatimento na fatura do convênio (só se a venda teve convênio; o faturamento é da Etapa 7);
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
  - O filtro "Abatimento no convênio" é a lista dos abatimentos a fazer na próxima fatura de cada convênio. O faturamento em si chega na Etapa 7.

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

- **No caixa:** o controlado lido abre o aviso "Preencher a receita". Cada controlado fica no seu item, com receita e lote próprios.
  - **Receita:** tipo (sugerido pela lista do produto: A → notificação A, B1 → notificação B, B2 → B2, C2 → retinoide, C3 → talidomida, antimicrobiano → receita de antimicrobiano, demais → controle especial), número (obrigatório nas notificações) e data.
  - **Validade:** 30 dias da data da receita; antimicrobiano, 10. Vencida ou com data no futuro é recusada (FA987).
  - **Prescritor:** nome, conselho (CRM, CRO, CRMV, COREN, CRF, RMS), número e UF.
  - **Comprador:** nome, documento (RG, CPF, CNH, passaporte ou outro), número, órgão emissor e UF.
  - **Paciente:** opcional; idade e sexo obrigatórios no antimicrobiano.
  - **Lote:** só os lotes com saldo e não vencidos da cópia local, o que vence primeiro antes. Quantidade acima do saldo do lote é recusada (FA988).
  - **Liberação:** código e PIN de quem tem `controlled.dispense` (perfil Farmacêutico; FA985 para os demais).
- **Pendente (estoque negativo):** sem lote com saldo para a quantidade, o farmacêutico libera com um motivo, sem os dados da receita. Com lote com saldo, a liberação pendente é recusada (FA989). Os dados do SNGPC são completados na manutenção (Etapa 8).
- **Na central:** `controlled_dispensing` guarda receita, comprador, lote e farmacêutico, e não muda depois.
  - Dados que a tabela recusa viram conflito (FA990).
  - Viram alerta da venda: controlado sem os dados, liberado por quem não tinha a permissão, pendente, receita vencida ou futura, tipo de receita diferente do da lista.
- **Retaguarda:** `/controlados` lista por situação (todas, pendentes, completas) e período, com o documento do comprador mascarado. Exige `controlled.view` (Farmacêutico e Gerente).
- **Dados pessoais:** vão só pela outbox e ficam no banco local criptografado e na central. Não entram no log nem no comprovante (que mostra lote, receita e farmacêutico).
- **Seed:** Clonazepam de demonstração (lista B1, código de barras 7890000000055) com o lote CLZ01 na Loja Centro. O Administrador (PIN 2580) pode liberar.

## Clientes

- **Cadastro:** único na rede, com código humano. Pessoa física com CPF ou jurídica com CNPJ, ambos com dígito validado e sem repetir no grupo. Só nome e documento são obrigatórios.
- **Dados pessoais:** mensagens e detalhes de erro do banco levam só identificadores. A API descarta o detalhe do Postgres no log, que traria o valor da chave. A lista mostra o documento mascarado, e a ficha mostra completo.
- **Consentimento:** cada concessão ou revogação é uma linha que nunca muda. A mais recente vale. Repetir a decisão atual não gera registro.
- **Reconhecimento facial:** só a decisão é registrada. O sistema não guarda imagem nem biometria.
- **Consulta de CNPJ:** em cascata, BrasilAPI, ReceitaWS e CNPJá, com 5 segundos por serviço. Só preenche a tela, e a pessoa confere antes de salvar. Os serviços devolvem também os sócios, e isso nunca é repassado nem gravado em log.
- **Inscrição estadual:** confere o tamanho esperado em cada estado, ou ISENTO. O dígito verificador entra com o Fiscal.
- **Convênios:** cadastro e vínculo com matrícula e limite, com `agreements.manage` em todas as filiais, porque o limite é crédito da rede.
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
