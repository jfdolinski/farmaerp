# FarmaERP – Passo a passo da base

Documento de estruturação da base do sistema. Stack: Flutter (PDV, multiplataforma inclusive Android), SQLite local enxuto, PostgreSQL central, NestJS (API) e Next.js (retaguarda web). Regras de negócio e conformidade ficam no banco (triggers, procedures, views). Usabilidade é a prioridade do projeto inteiro.

## Etapa 1 – Fundação

**Repositório**

- Monorepo com app Flutter, API NestJS, web Next.js e pasta dedicada ao banco (migrations, triggers, procedures e views versionadas).

**Identidade dos dados**

- UUID v7 como chave primária em todas as tabelas, gerado no próprio PDV (funciona offline, ordenado por tempo).
- Armazenamento binário: tipo uuid no Postgre, blob de 16 bytes no SQLite.
- Código humano curto para tela e cupom: produto e cliente com sequência única por grupo econômico; venda com número do terminal + contador do terminal (ex.: `2-000123`), gerado mesmo offline. Cliente criado offline fica sem código até sincronizar. O código nunca muda nem é reaproveitado e não substitui o número fiscal.
- Exclusão lógica (data de exclusão), nada é apagado fisicamente.
- Campos de auditoria e versão em toda tabela: criado em, atualizado em, versão, alterado por.

**Multifilial**

- Hierarquia: grupo econômico > empresa (CNPJ) > filial > terminal, com agrupamentos de filiais (regiões).
- Row Level Security liberando o conjunto de filiais que cada usuário pode ver.
- Relatórios por filial ou somados/consolidados, com subtotais por agrupamento.
- Views comuns para consultas do dia a dia; views materializadas com atualização agendada para relatórios pesados e consolidados. A API envia só resultados resumidos para economizar banda.

**Terminais**

- Primeira abertura: o app gera par de chaves no aparelho e exibe código curto ou QR code.
- Solicitação pela retaguarda ou pelo app do funcionário (leitura do QR), escolhendo a filial.
- Aprovação com nome do terminal e perfil (orçamento, caixa ou autoatendimento).
- Carga inicial do SQLite da filial antes de liberar vendas.
- Monitoramento: online/offline, último sync, pendências do outbox; bloqueio e revogação imediatos.
- Séries da NFC-e (65) e da NF-e (55) amarradas a cada terminal.

**Padrões**

- Logs estruturados com ID de rastreio do PDV até o banco; PDV guarda logs locais e envia no sync.
- Catálogo padronizado de códigos de erro: mensagem clara para o operador, detalhe técnico no log.
- Ambientes de desenvolvimento, homologação (Sefaz e Anvisa de teste) e produção.
- CI rodando testes do banco, triggers, procedures e sync antes de qualquer deploy.

## Etapa 2 – Núcleo de dados (Postgre)

### Produtos

- **Produto do Catálogo** (global, atualizado só pelo Catálogo): nome padrão, princípio ativo, fabricante, MS base, classificação de controlado, NCM, CEST, tributação por regime e estado, imagens, CMED.
- **Códigos de barras** em tabela própria, vários por produto, cada um com: principal (único, vai para etiqueta), envia para fornecedor, integra com marketplace/canais (tabela de canais extensível), ativo na leitura do PDV.
- **Produto da loja** (cadastro comercial único para toda a rede): nome de exibição, departamento > categoria > subcategoria, grupo de comissão, grupo de precificação, grupo de preço (família), flag PMC, bloqueio de venda online.
- **Preço** em tabela própria: padrão da rede com exceção por filial e histórico. Custo e estoque por filial.
- **PMC** por estado e região especial (área de livre comércio, Zona Franca), atualizado pela nota e pela CMED; se PMC da nota vier menor que o preço de venda, só avisa.
- **Status por filial** (grade no cadastro, uma linha por filial, com ação em massa):
  - Ativo: funciona normalmente.
  - Somente encomenda: ativo e vendável, fora do pedido de compra automático; sem estoque, avisa o vendedor que só sai por encomenda.
  - Bloqueado: vende o estoque restante, não entra em nenhum pedido; zerado, some da venda e da compra e só aparece na pesquisa do cadastro.
  - Inativo: igual ao bloqueado, mas não aparece nem na pesquisa do cadastro; filtro "mostrar inativos" para localizar e reativar com autenticação.
  - Toda mudança registra quem, quando e motivo.

**Fracionamento em três níveis** (o mais específico prevalece): produto, código de barras e relação produto-fornecedor.

**Entrada do XML – validação do item**

1. Busca o código do fornecedor da nota; achou, aplica o fracionamento da relação.
2. Busca pelo código de barras; achou, aplica o fracionamento do EAN e cria a relação com o fornecedor.
3. Relacionamento manual com produto existente; os novos códigos de fornecedor e de barras são adicionados sem apagar os existentes.
4. Item sem cadastro: primeira opção é duplicar cadastro; cadastro do zero consulta o Catálogo e preenche, com confirmação do usuário. Cadastro automático pelo Catálogo fica pronto, desligado por parâmetro.

- Segurança: custo líquido unitário (fracionado, com impostos e descontos) comparado ao custo médio; acima da tolerância, a linha trava até autenticação.

**Motor de regras de produto** (usado em tolerância, descontos, comissões, cashback, limites e demais regras). Hierarquia, do mais específico ao mais geral:

1. Produto
2. Grupo de preço (família)
3. Fabricante
4. Subcategoria
5. Categoria
6. Departamento
7. Grupo de precificação
8. Grupo de comissão
9. Padrão da loja

- Prioridade manual opcional para desempate.

### Estoque

- Movimentações imutáveis como fonte da verdade (nota, venda, devolução, transferência, ajuste, perda, inventário); correções por movimentação contrária.
- Saldo por produto, filial e lote, atualizado por triggers; total da rede por view.
- Lote e validade vindos da nota; baixa pelo vencimento mais próximo; lote obrigatório para controlados.
- MS por lote: o lote herda o MS base, ou recebe o MS do XML quando vier; divergência com o MS base gera aviso, com edição permitida e registro do valor original.
- PDV guarda só uma cópia de consulta do saldo.
- Venda offline com saldo local zerado: liberada só se o PDV estiver comprovadamente sem sincronizar há mais que o tempo mínimo (configurável por filial e por terminal), com aviso e autenticação do gerente; registro completo, relatório pós-sync e alerta de terminais com quedas frequentes.

### Clientes

- Cadastro único na rede, CPF obrigatório; sem CPF, venda como consumidor não identificado.
- CPF sem busca automática (LGPD). CNPJ com autopreenchimento por APIs gratuitas em cascata (BrasilAPI, ReceitaWS, CNPJá), aviso de CNPJ inativo/baixado; inscrição estadual via Sintegra ou digitada.
- Dependentes vinculados ao CPF do titular, com nome, grau de parentesco e data de nascimento (CPF opcional).
- Convênios com matrícula, limite e regras.
- Consentimento LGPD por finalidade (marketing, reconhecimento facial, cashback), revogável.
- Histórico de compras, uso contínuo, cashback e vale-crédito.

### Usuários e permissões

- Usuário único na rede, vinculado às filiais em que atua.
- Perfis com regras definidas e relacionados a várias pessoas (inclusive o perfil farmacêutico); uma pessoa pode ter vários perfis, com permissões somadas e prevalência do maior limite.
- Permissões granulares por ação, com limites de valor que também usam o motor de regras.
- Visibilidade de dados conforme filiais habilitadas e permissão de ver outros usuários.
- Liberação de supervisor registrando quem pediu, quem liberou e o motivo.

### Fiscal

- Tributação pelo Catálogo, separada por regime; a loja não edita.
- Por CNPJ: regime (a rede terá regimes diferentes), IE, certificado A1 criptografado, CSC.
- Numeração reservada no SQLite por terminal e série.
- Contingência offline com transmissão automática e alerta de prazo.

## Etapa 3 – SQLite enxuto e sincronização

- **No SQLite**: produtos ativos e por encomenda (bloqueados só enquanto houver saldo; inativos não descem), códigos de barras, preço da filial, tributação pronta, promoções e descontos vigentes, usuários e perfis da loja, cópia do estoque, configuração fiscal e outbox.
- **Clientes**: todos os clientes com débito no crediário, da rede inteira, descem para todos os terminais e ficam sempre sincronizados (pagamento em qualquer loja). Demais clientes são buscados online e gravados sob demanda.
- **Descida** incremental por versão, em pacotes compactados.
- **Subida** pelo outbox, na mesma transação local, em ordem; UUID garante que reenvio não duplica.
- **Conflitos**: o Postgre decide; casos ficam visíveis na retaguarda. Pagamento duplicado da mesma parcela em lojas offline vira crédito do cliente, com alerta.

## Etapa 4 – PDV e fluxo de venda

- Um único app com três modos por perfil de terminal: orçamento, caixa e autoatendimento; também instalável no Android para o vendedor.
- Abertura: autenticação e, no caixa, abertura de turno com fundo de troco.
- Montagem: identificação do cliente, busca por código de barras, nome, princípio ativo e fabricante, estoque de outras filiais, motor de descontos com explicação e avisos (controlado, encomenda, sem estoque).
- Controlados: dados da receita e do comprador, lote e liberação do farmacêutico. Com estoque negativo, a venda pode ser liberada com senha e sem dados SNGPC na hora, que são ajustados depois na tela de manutenção.
- Pagamento misto: dinheiro, PIX, cartão/TEF, crediário, cashback, convênio, vale-crédito.
- Margem mínima (parâmetro futuro, desligado): custo médio vs preço vendido, calculada sobre a venda inteira e sem considerar desconto de PBM; abaixo do mínimo, trava, com liberação do gerente conforme parâmetro.
- Finalização com escolha do modelo de nota: 65 imprime o cupom; 55 abre os campos obrigatórios (CPF/CNPJ, endereço, IE) puxando do cadastro, transmite à Sefaz e abre a DANFE A4. Comprovante por WhatsApp.
- Pós-venda: troca e devolução só na loja da compra (por questão fiscal), vinculadas à venda original; o cliente escolhe vale-crédito (válido na rede) ou estorno no meio original.
- Orçamento com plaquinhas ou cupom, sangria em três níveis, fechamento com conferência cega (já definidos).

## Etapa 5 – Autenticação

- PIN, digital e rosto num serviço único; o método é definido por usuário (os três, só PIN, só câmera ou só biometria).
- Tela inicial com câmera reconhecendo e identificando sozinha; botão "entrar de outra forma" com código de usuário e o método configurado.
- Falha da câmera em usuário configurado para câmera: digita o código e o gerente libera, com registro.
- Reconhecimento facial com prova de vida, só o código numérico guardado (nunca a imagem), comparação local e offline.
- Cliente: o rosto identifica e o PIN confirma; só com consentimento LGPD.
- Códigos de funcionários descem para as filiais deles; os de clientes seguem o recorte de clientes.

## Etapa 6 – App do funcionário

- Sem vendas (vendas pelo PDV no Android).
- Liberações: notificação para os gerentes, aprovação com rosto ou digital, resposta imediata ao PDV; offline, a liberação é feita no terminal.
- Metas por filial, funcionário e período (faturamento, quantidade, produto, fabricante), em tempo real.
- Comissões pelo grupo de comissão e motor de regras, extrato venda a venda, devoluções descontadas.
- Comparecimento por geolocalização com raio por filial; não é ponto.
- Visibilidade conforme permissões e filiais habilitadas.

## Etapa 7 – Financeiro do cliente

- **Crediário**: conta titular e dependentes, venda > parcelas, recebimentos parciais e todas as formas de pagamento, juros, multa e atraso; limite sugerido pelo sistema e ajustado manualmente com registro.
- **Cashback**: meio de pagamento, gerado só sobre o valor pago; o valor pago com cashback não gera cashback novo; carência, validade, limite e extrato.
- **Descontos**: dez tipos no motor de regras, cada regra acumulável ou exclusiva; entre exclusivas, vale a de maior desconto, respeitando margem mínima e PMC.

## Etapa 8 – Fiscal e regulatório

- **Notas**: 65 e 55 emitidas pelo PDV, mesmo motor fiscal.
- **Carta de correção**: quando lote ou MS forem alterados na entrada, a nota fica com pendência; o sistema monta a solicitação ao fornecedor (único que pode emitir a CC-e), consulta os eventos das notas destinadas na Sefaz, vincula a CC-e ao receber e avisa para cobrar se demorar. Confirmar a obrigação com a contabilidade.
- **SNGPC** (API nova da Anvisa):
  - Tela de manutenção como entreposto: toda movimentação de controlado (entradas, saídas, vendas, transferências) fica pendente até o farmacêutico conferir, autenticar e definir a data de envio. Nada automático; avisos de prazo.
  - Sem confirmação e data, a movimentação não entra no XML.
  - Transmissão em ordem cronológica; pendência segura as movimentações posteriores do produto.
  - No XML, entradas antes das saídas.
  - Simulação de saldo por lote antes de confirmar; bloqueio com motivo quando a saída fica antes da entrada do lote ou o saldo fica negativo; correção guiada sugerindo data de saída igual ou posterior à entrada.
  - Cada movimentação usa o MS do seu lote.
- **PBMs**: conector por programa e fluxo único no PDV (identifica, consulta elegibilidade, aplica, confirma); desconto exclusivo e fora da margem mínima.

## Etapa 9 – Canais externos

- **WhatsApp**: um número por filial; conversas pelo WhatsApp Web dentro do PDV; envios em massa pela API oficial; SMS como canal secundário.
- **App de pedidos**: link para o cliente, login com CPF, pedido direto no sistema, bloqueio de controlados/receita pelo cadastro. Escolha da filial: primeiro a loja de saída da região, depois o estoque nas lojas mais próximas. Pedido incompleto: parametrizável por loja, com opção de solicitar transferência às lojas que têm estoque e entregar tudo junto; prazo informado por WhatsApp.
- **App do entregador**: entregadores compartilhados pela rede, despacho pelo mais próximo da loja de envio, aceite com valor e pontos A/B, rastreio por link no WhatsApp. Valor: taxa base mais valor por km, com faixas pelo valor da compra (desconto/grátis), e o entregador sempre recebe. Pagamento na entrega por maquininha e PIX pelo app, com controle do valor em posse do entregador.

## Distribuição e atualização automática

- Instalador desktop simples (Windows "avançar e concluir"; Linux pacote único).
- Serviço de atualizações na VPS, arquivos assinados; PDV baixa em segundo plano e aplica só em momento seguro (fechamento de caixa ou próxima abertura), com migração do SQLite e retorno à versão anterior em caso de falha.
- Liberação gradual pela retaguarda e visão da versão de cada terminal.
- Apps de celular pela Play Store com atualização dentro do app e versão mínima obrigatória.

## Pendências

- Compras: estoque mínimo e máximo e inteligência de compras, em conversa separada.
- Cadastro automático pelo Catálogo, quando ele estiver maduro.
- Ambiente Android (Android Studio) para os apps de celular.
