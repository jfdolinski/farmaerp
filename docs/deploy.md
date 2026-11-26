# Publicação no EasyPanel

Guia para publicar a homologação e, depois do login, a produção. Os nomes dos botões do EasyPanel podem mudar entre versões. Este guia foi conferido na publicação real da homologação, no EasyPanel 2.37.

**Homologação atual:** API em `https://farmaerp-hom-api.b6nhiy.easypanel.host` e retaguarda em `https://farmaerp-hom-web.b6nhiy.easypanel.host`.

## Os ambientes

| | Desenvolvimento | Homologação | Produção |
|---|---|---|---|
| `APP_ENV` | `development` | `homologation` | `production` |
| Onde | Docker Compose local | Projeto próprio no EasyPanel | Projeto próprio no EasyPanel |
| Dados | Seed | Seed, nunca dados reais | Reais |
| Primeiro acesso | Seed, com senha de exemplo | Variáveis `BOOTSTRAP_` | Variáveis `BOOTSTRAP_` |
| Publicação | Manual | Automática após o CI na `main` | Manual |

**A produção ainda não deve ser publicada.** Veja [Antes de publicar a produção](#antes-de-publicar-a-produção).

## Publicar a homologação

### 1. Antes de começar

- **Limite de projetos:** a licença gratuita permite 3 projetos por servidor.
- **Painel em HTTPS:** acesse o painel pelo endereço com HTTPS mostrado em **Configurações > Geral**, nunca pelo IP. Veja [Segurança do painel](#segurança-do-painel).
- **Token do GitHub:** o repositório é privado. Crie um [token granular](https://github.com/settings/personal-access-tokens/new) só para o repositório `farmaerp`, com **Contents** em **Read-only** e expiração de 90 dias. Cole em **Configurações > Github**.
- **Endereços:** cada serviço recebe um endereço gratuito com HTTPS no formato `<projeto>-<serviço>.<servidor>.easypanel.host`. Para usar um domínio próprio, crie um registro **A** apontando para o IP da VPS e adicione o domínio ao serviço.

### 2. Projeto e banco

1. Crie um projeto chamado `farmaerp-hom`.
2. Crie um serviço **Postgres** chamado `postgres`, com banco `farmaerp`, usuário `postgres` e imagem `postgres:18.6`.
3. Deixe a senha em branco, para o painel gerar uma aleatória. Ela fica em **Credenciais**.
4. **Não** exponha a porta do banco. O endereço interno é `farmaerp-hom_postgres`.

### 3. Segredos

Gere um valor diferente para cada segredo abaixo, rodando este comando uma vez para cada um:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Guarde os valores só no EasyPanel. Nunca os coloque no repositório nem os reutilize em outro ambiente.

### 4. Serviço da API

Crie um serviço **App** chamado `api`:

- **Origem:** GitHub, repositório `jfdolinski/farmaerp`, branch `main`, **Caminho de Build** `/`.
- **Build:** **Dockerfile**, com o arquivo `apps/api/Dockerfile`.
- **Domínio:** o endereço gratuito já vem criado, mas aponta para a porta `80`. Edite e troque a porta para `3001`.

Variáveis:

| Nome | Valor |
|---|---|
| `APP_ENV` | `homologation` |
| `DB_HOST` | `farmaerp-hom_postgres` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `farmaerp` |
| `TRUST_PROXY` | `true` |
| `FARMAERP_MIGRATOR_PASSWORD` | Segredo gerado |
| `FARMAERP_APP_PASSWORD` | Segredo gerado |
| `TERMINAL_TOKEN_SECRET` | Segredo gerado |
| `FISCAL_ENCRYPTION_KEY` | Chave gerada, 32 bytes em base64 (veja "Atualizar para a configuração fiscal") |
| `RELEASES_DIR` | `/data/releases` (volume das versões do PDV; veja "Atualizar para as versões do PDV") |
| `RELEASE_UPLOAD_TOKEN` | Segredo gerado, com ao menos 32 caracteres (o mesmo do segredo do GitHub) |
| `POSTGRES_ADMIN_PASSWORD` | Senha do banco (passo 2). **Só no primeiro deploy** |
| `BOOTSTRAP_ADMIN_EMAIL` | E-mail do primeiro administrador. **Só no primeiro deploy** |
| `BOOTSTRAP_ADMIN_PASSWORD` | Senha inicial, com ao menos 10 caracteres. **Só no primeiro deploy** |
| `BOOTSTRAP_GROUP_NAME` | Nome do grupo econômico, se ainda não existir nenhum. **Só no primeiro deploy** |

Clique em **Implantar** e confira `/health` no endereço da API.

Entre na retaguarda com o e-mail e a senha inicial, e defina a senha definitiva.

Depois disso, **apague `POSTGRES_ADMIN_PASSWORD` e as variáveis `BOOTSTRAP_`**, salve e clique em **Implantar** de novo. A API deve subir normalmente sem elas.

### 5. Serviço da retaguarda

Crie um serviço **App** chamado `web`, com a mesma origem:

- **Caminho de Build:** `/`
- **Build:** **Dockerfile**, com o arquivo `apps/web/Dockerfile`.
- **Domínio:** edite o endereço gratuito e troque a porta `80` por `3000`.
- **Aba Segurança (só na homologação):** crie um usuário e uma senha de acesso **antes de publicar**. Essa camada a mais mantém a homologação fora do alcance de visitantes. A produção usa só o login do sistema.

Variáveis:

| Nome | Valor |
|---|---|
| `APP_ENV` | `homologation` |
| `API_URL` | `http://farmaerp-hom_api:3001` (endereço interno) |

Clique em **Implantar**. O build roda na própria VPS, então publique um serviço de cada vez.

### 6. Publicação

**Hoje a publicação é manual:** clique em **Implantar** em cada serviço, primeiro na API e depois na retaguarda.

O CI já sabe publicar depois do `ci-ok`, mas continua desligado enquanto estes segredos não existirem:
- `EASYPANEL_DEPLOY_HOM_API`
- `EASYPANEL_DEPLOY_HOM_WEB`

Antes de ligar, resolva dois pontos:
- **Endereço da URL:** o painel mostra a URL de deploy com o IP e a porta `3000`, sem criptografia. Confirme se a mesma rota funciona pelo endereço HTTPS do painel.
- **Método HTTP:** a documentação do EasyPanel não informa qual usar. O CI usa POST, o que ainda não foi testado.

A URL contém um token, então trate-a como senha.

### 7. Conferência

- [ ] `https://farmaerp-hom-api.b6nhiy.easypanel.host/health` responde `{"status":"ok","database":"up"}`.
- [ ] `https://farmaerp-hom-api.b6nhiy.easypanel.host/admin/terminals` responde com erro `FA402`.
- [ ] `https://farmaerp-hom-web.b6nhiy.easypanel.host` pede usuário e senha.
- [ ] Depois da senha de acesso, a retaguarda pede o login e mostra a faixa de homologação.
- [ ] Depois do login, aparece o terminal `1 · Caixa 1`.
- [ ] O banco não responde de fora: a porta `5432` da VPS está fechada.
- [ ] `POSTGRES_ADMIN_PASSWORD` e as variáveis `BOOTSTRAP_` não estão mais na API.

### 8. PDV apontando para a homologação

Em `apps/pdv`:

```bash
flutter run -d windows --dart-define=APP_ENV=homologation --dart-define=API_URL=https://farmaerp-hom-api.b6nhiy.easypanel.host
```

Fora de desenvolvimento, o PDV recusa um endereço que não seja HTTPS.

**Atenção:** a chave do terminal fica em `%APPDATA%\br.com.farmaerp\farmaerp_pdv`, a mesma pasta em qualquer ambiente. Ao alternar entre desenvolvimento e homologação na mesma máquina, o PDV tenta usar o terminal do outro ambiente. Para recomeçar, feche o PDV e apague essa pasta.

## Segurança do painel

- **Use só o endereço com HTTPS.** Ele fica em **Configurações > Geral**, na seção **Domínio do Painel**.
- **Feche a porta `3000`.** Desmarcar **Servir no endereço IP** não basta: o painel continua abrindo em `http://<ip>:3000`. Bloqueie essa porta no firewall da Hostinger e mantenha abertas a `22`, a `80` e a `443`.
- **Troque as credenciais usadas pelo IP.** Senha do painel, token do GitHub e senhas coladas passaram sem criptografia enquanto o acesso era por `http://`.

## Atualizar uma homologação publicada antes do login

1. Em **api > Ambiente**, apague `ADMIN_INTERNAL_SECRET` e acrescente `BOOTSTRAP_ADMIN_EMAIL` e `BOOTSTRAP_ADMIN_PASSWORD`.
2. Em **web > Ambiente**, apague `ADMIN_INTERNAL_SECRET`.
3. Clique em **Implantar** na API e, depois, na retaguarda.
4. Entre na retaguarda com o novo e-mail e defina a senha definitiva.
5. Apague as variáveis `BOOTSTRAP_` da API e clique em **Implantar** de novo.

Os terminais já aprovados continuam funcionando.

## Zerar a homologação e recriar o acesso

Só na homologação, e só com o pedido do responsável. Os dados de teste são apagados de vez.

1. No console do Postgres (ícone `>_`, **Postgres Client**), conecte com `\c farmaerp` e confira o nome do banco e do projeto.
2. Rode, numa linha só:
   `BEGIN; DROP SCHEMA app, db_migrations, ext, public CASCADE; CREATE SCHEMA public; GRANT CREATE, USAGE ON SCHEMA public TO farmaerp_migrator; GRANT USAGE ON SCHEMA public TO farmaerp_app; COMMIT;`
3. Em **api > Ambiente**, acrescente `BOOTSTRAP_ADMIN_EMAIL` e `BOOTSTRAP_ADMIN_PASSWORD` (a senha que você vai usar, com ao menos 10 caracteres). O seed da homologação não cria senha: a de exemplo é pública e só existe em desenvolvimento.
4. Clique em **Implantar** na API: as migrations e o seed recriam tudo, e o administrador do deploy entra no grupo de demonstração e administra a plataforma.
5. Entre na retaguarda com esse e-mail, defina a senha definitiva, apague as variáveis `BOOTSTRAP_` e implante a API de novo.
6. Cadastre as empresas em **Plataforma** e pareie os terminais de novo (no PDV, se preciso, apague a pasta `%APPDATA%\br.com.farmaerp\farmaerp_pdv`).

## Atualizar para perfis e permissões

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. A migration dá o perfil Administrador a quem era administrador, e os demais usuários ficam sem perfil, até um administrador atribuir.

## Atualizar para o cadastro de produtos

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. A migration ativa as extensões `pg_trgm` e `unaccent`, que já vêm na imagem oficial do PostgreSQL, e o Gerente passa a ver produtos. Em homologação, o seed cria um Catálogo fictício.

## Atualizar para preço, PMC e status por filial

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. Toda filial e produto recebem uma linha de status ativa. Depois, informe o estado de cada filial em **Produtos > Estrutura**: sem ele, produto com a flag PMC não aceita preço.

## Atualizar para o motor de regras

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. Em homologação, o seed cria regras fictícias. Em produção não nasce nenhuma regra, porque os percentuais são decisão de cada rede.

## Atualizar para o estoque

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. O Gerente passa a ver o estoque e a registrar perdas. Em homologação, o seed cria um saldo fictício.

## Atualizar para transferência e inventário

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda.

## Atualizar para o cadastro de clientes

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. O Gerente passa a ver e cadastrar clientes. Em homologação, o seed cria um cliente fictício.

## Atualizar para convênios e consulta de CNPJ

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. A API passa a consultar `brasilapi.com.br`, `receitaws.com.br` e `open.cnpja.com` quando alguém pede a consulta de um CNPJ: se a VPS bloquear saída para a internet, a consulta avisa e o cadastro segue manual.

## Atualizar para as séries por terminal

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. Os terminais de caixa e de autoatendimento já aprovados recebem as séries automaticamente, e elas aparecem em **Fiscal**.

## Atualizar para o cadastro de empresas e filiais

Nenhuma variável muda. Clique em **Implantar** na API e, depois, na retaguarda. Numa produção nova, a primeira empresa é cadastrada em **Empresas**, logo depois do primeiro acesso.

## Atualizar para a configuração fiscal

Esta atualização tem **uma variável nova**, então crie a variável antes de implantar:

1. Gere a chave no seu computador. O valor aparece só no seu terminal:

   ```bash
   node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
   ```

2. No serviço `api`, em **Ambiente**, inclua `FISCAL_ENCRYPTION_KEY` com esse valor e salve.
3. Implante a API, confira e implante a retaguarda.

Cuidados com a chave:

- Use uma chave diferente em cada ambiente, e nunca a versione.
- Guarde uma cópia fora da VPS, como as outras senhas. O backup do banco não traz a chave: sem ela, o que está guardado não abre, e cada filial precisa enviar de novo o certificado e o CSC.
- Trocar a chave tem o mesmo efeito. Só troque se ela tiver vazado, e peça o reenvio em todas as filiais.

Sem a variável, a API sobe normalmente: só o envio de certificado e de CSC fica indisponível, com o código FA915.

## Atualizar para as versões do PDV

A central passa a guardar as versões do PDV e a entregar a atualização aos terminais. São **um volume e duas variáveis novas** no serviço `api`. Sem elas, a API sobe normalmente: só o envio de versões (FA876) e o download pelos PDVs (FA875) ficam indisponíveis.

1. No serviço `api`, em **Montagens** (Mounts), crie um **volume** com o nome `releases` e o caminho de montagem `/data/releases`. O volume guarda os instaladores entre um deploy e outro.
2. Gere o token de envio no seu computador. O valor aparece só no seu terminal:

   ```bash
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   ```

3. Em **Ambiente**, inclua `RELEASES_DIR` com `/data/releases` e `RELEASE_UPLOAD_TOKEN` com o token. Salve.
4. Implante a API, confira e implante a retaguarda.
5. No GitHub (Settings → Secrets and variables → Actions), cadastre o mesmo token no segredo `RELEASE_UPLOAD_TOKEN`.
6. Gere a chave de assinatura das versões, **uma vez**, no seu computador, com um arquivo **fora** do repositório:

   ```bash
   node scripts/release/generate-update-key.mjs C:caminhoseguroarmaerp-update-key.txt
   ```

   - O conteúdo do arquivo (chave privada) vai no segredo `UPDATE_SIGNING_KEY` do GitHub: `gh secret set UPDATE_SIGNING_KEY < C:caminhoseguroarmaerp-update-key.txt`. Guarde uma cópia em local seguro e não mande por chat.
   - A chave pública, mostrada na tela, entra em `scripts/release/update-keys.json`, `apps/api/src/releases/update-keys.ts` e `apps/pdv/lib/update/update_signature.dart` (os testes conferem que são iguais). Só depois disso o CI consegue publicar.

### Publicar uma versão do PDV

1. Com o `main` como deve ir para as lojas, crie a tag: `git tag pdv-v1.2.3` e `git push origin pdv-v1.2.3`.
2. O workflow "Versão do PDV" gera e assina o instalador e envia para a homologação, só para os terminais de teste. O instalador também fica nos artefatos do workflow, para a primeira instalação em uma máquina nova.
3. Confira nos terminais de teste (Terminais → versão e última atualização) e libere para a rede em `/plataforma/versoes`.

Cuidados:

- Use um token diferente em cada ambiente e nunca o versione.
- Quem tem o token consegue enviar arquivos, mas não consegue publicar versão que o PDV aceite: o PDV só instala o que estiver assinado com a chave que só o CI tem.
- As versões ficam em `/plataforma/versoes`, só para o administrador da plataforma: liberar para a rede ou retirar. Em Terminais, cada cliente marca os terminais de teste, que recebem a versão primeiro.

## Atualizar para o envio do SNGPC

Não há variável obrigatória nova. A credencial do SNGPC de cada filial é criptografada com a `FISCAL_ENCRYPTION_KEY` que já existe; sem ela, o cadastro da credencial responde FA915.

O envio real fica **desligado** até a documentação da API nova da Anvisa ser conferida. Para ligar, mais tarde, no serviço `api`:

| Nome | Valor |
|---|---|
| `SNGPC_LIVE` | `true` |
| `SNGPC_URL` | Endereço HTTPS do SNGPC (da documentação oficial) |

Desligado, a rotina monta as remessas e espera; nada sai da VPS.

## Antes de publicar a produção

A produção usa os mesmos passos, em um projeto próprio e com segredos próprios, mas depende destes itens:

- [ ] VPS própria, sem dividir recursos com outros sistemas.
- [ ] Decisão sobre como publicar: manualmente pelo painel, sem o job automático.
- [ ] [Backup diário do banco](https://easypanel.io/docs/backups/database), com destino fora da VPS.
- [ ] Restauração testada: recupere um backup em um banco separado e confira os dados. Backup sem restauração testada não é garantia.
- [ ] Prazo de retenção do IP nos logins (90 dias hoje) confirmado com o jurídico ou a contabilidade.
- [ ] `FISCAL_ENCRYPTION_KEY` própria da produção, com cópia guardada fora da VPS.
- [ ] Volume `/data/releases` e `RELEASE_UPLOAD_TOKEN` próprios da produção.
- [ ] Certificado de assinatura de código (Authenticode) para o instalador do PDV, para o Windows não mostrar "Editor desconhecido" na primeira instalação.

O seed se recusa a rodar em produção, e a senha de exemplo existe só em desenvolvimento.

## Variáveis e segurança

- **Senhas no contêiner:** o `docker-entrypoint.sh` remove a senha de dono antes de iniciar a API, então o processo não a recebe. Quem tem acesso ao painel ou ao console do contêiner ainda consegue vê-la.
- **Variáveis no build:** o EasyPanel repassa as variáveis como argumentos de build. Os Dockerfiles não as declaram, para que não fiquem gravadas na imagem. Não acrescente `ARG` com segredos.
- **Capacidade:** a VPS atual tem 1 núcleo e 3,8 GB de memória e é compartilhada com o `etiquetas-saas`. Serve para homologação, mas a produção da rede deve ter uma VPS própria.
- **Credenciais iniciais:** `BOOTSTRAP_ADMIN_PASSWORD` só serve para o primeiro acesso, porque a troca é obrigatória. Se o e-mail já tiver acesso, a variável é ignorada e nunca sobrescreve a senha.
- **Uma instância:** o limite de tentativas fica em memória, então a API deve rodar com uma única réplica por enquanto.

## Problemas comuns

| O que aparece | O que fazer |
|---|---|
| `A variável APP_ENV precisa ser...` | Confira o valor de `APP_ENV` |
| `Configuração inválida: ...` | A mensagem lista as variáveis faltando ou curtas |
| `O banco recusou o acesso` | No primeiro deploy, defina `POSTGRES_ADMIN_PASSWORD`. Depois, confira `FARMAERP_MIGRATOR_PASSWORD` |
| `Falha ao preparar o banco` | Confira `DB_HOST` e os logs do banco. A versão anterior deve ser mantida |
| Retaguarda volta sempre ao login | Em ambiente publicado, o cookie exige HTTPS: confira se o endereço usa `https://` |
| Retaguarda mostra `FA001` | Confira `API_URL` e se a API está no ar |
| `Cannot find public repository and your Github token is missing` | Configure o token em **Configurações > Github** |
| Endereço responde `Bad Gateway` | Confira se o domínio aponta para a porta do serviço (`3001` na API, `3000` na retaguarda) |

Para testar as imagens localmente, sem o EasyPanel:

```bash
npm run test:images
```
