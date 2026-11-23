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
- **Offline:** a liberação sem internet no PDV depende da sincronização de usuários e perfis, na Etapa 3.

## Produtos

- **Catálogo:** tabelas globais `catalog_*`, sem grupo econômico. A API só lê; quem escreve é `npm run catalog:import`, com o papel dono das tabelas.
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
