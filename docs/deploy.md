# Publicação no EasyPanel

Guia para publicar a homologação e, depois do login, a produção. Os nomes dos botões do EasyPanel podem mudar entre versões. Nos exemplos, troque `exemplo.com.br` pelo domínio de vocês.

## Os ambientes

| | Desenvolvimento | Homologação | Produção |
|---|---|---|---|
| `APP_ENV` | `development` | `homologation` | `production` |
| Onde | Docker Compose local | Projeto próprio no EasyPanel | Projeto próprio no EasyPanel |
| Dados | Seed | Seed, nunca dados reais | Reais |
| Identidade | Seletor de usuário | Seletor protegido | Só com login |
| Publicação | Manual | Automática após o CI na `main` | Manual |

**Hoje a API não inicia com `APP_ENV=production`.** A retaguarda ainda não tem login, então esse bloqueio impede que a identidade provisória seja publicada por engano.

## Publicar a homologação

### 1. Subdomínios

No site onde o domínio foi registrado, crie dois registros do tipo **A** apontando para o IP da VPS:

| Nome | Uso |
|---|---|
| `hom` | Retaguarda |
| `hom-api` | API |

### 2. Projeto e banco

1. Crie um projeto chamado `farmaerp-hom`.
2. Crie um serviço **PostgreSQL** chamado `postgres`, com a imagem `postgres:18.6`, banco `farmaerp` e usuário `postgres`.
3. **Não** exponha a porta do banco. Anote o endereço interno e a senha mostrados nas credenciais do serviço.

### 3. Segredos

Gere um valor diferente para cada segredo abaixo, rodando este comando uma vez para cada um:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Guarde os valores só no EasyPanel. Nunca os coloque no repositório nem os reutilize em outro ambiente.

### 4. Serviço da API

Crie um serviço **App** chamado `api`:

- **Origem:** GitHub, repositório `jfdolinski/farmaerp`, branch `main`, com o deploy automático do EasyPanel **desligado**.
- **Pasta de build:** `/`
- **Dockerfile:** `apps/api/Dockerfile`
- **Domínio:** `hom-api.exemplo.com.br`, com HTTPS e porta `3001`.

Variáveis:

| Nome | Valor |
|---|---|
| `APP_ENV` | `homologation` |
| `DB_HOST` | Endereço interno do banco (passo 2) |
| `DB_PORT` | `5432` |
| `DB_NAME` | `farmaerp` |
| `TRUST_PROXY` | `true` |
| `FARMAERP_MIGRATOR_PASSWORD` | Segredo gerado |
| `FARMAERP_APP_PASSWORD` | Segredo gerado |
| `TERMINAL_TOKEN_SECRET` | Segredo gerado |
| `ADMIN_INTERNAL_SECRET` | Segredo gerado |
| `POSTGRES_ADMIN_PASSWORD` | Senha do banco (passo 2). **Só no primeiro deploy** |

Publique o serviço e confira os logs. O primeiro deploy deve mostrar `Papéis do banco conferidos` e `Migrations aplicadas`.

Depois disso, **apague `POSTGRES_ADMIN_PASSWORD`** e publique de novo. Os logs devem mostrar `Nenhuma migration pendente`.

### 5. Serviço da retaguarda

Crie um serviço **App** chamado `web`, com a mesma origem:

- **Pasta de build:** `/`
- **Dockerfile:** `apps/web/Dockerfile`
- **Domínio:** `hom.exemplo.com.br`, com HTTPS e porta `3000`.
- **Aba Security:** crie um usuário e uma senha de acesso. Sem isso, qualquer pessoa com o endereço entra como administrador.

Variáveis:

| Nome | Valor |
|---|---|
| `APP_ENV` | `homologation` |
| `API_URL` | `https://hom-api.exemplo.com.br` |
| `ADMIN_INTERNAL_SECRET` | O mesmo valor usado na API |

### 6. Publicação automática

Na aba de deployments de cada serviço, copie a URL de deploy. Ela contém um token, então trate-a como senha. Rode cada comando abaixo e cole a URL quando ele pedir:

```bash
gh secret set EASYPANEL_DEPLOY_HOM_API --repo jfdolinski/farmaerp
```

```bash
gh secret set EASYPANEL_DEPLOY_HOM_WEB --repo jfdolinski/farmaerp
```

A partir daí, cada merge na `main` publica a homologação, mas só se o CI passar. Sem esses segredos, o job de publicação apenas avisa e não faz nada.

### 7. Conferência

- [ ] `https://hom-api.exemplo.com.br/health` responde `{"status":"ok","database":"up"}`.
- [ ] `https://hom-api.exemplo.com.br/admin/terminals` responde com erro `FA002`.
- [ ] `https://hom.exemplo.com.br` pede usuário e senha.
- [ ] A retaguarda mostra a faixa de homologação e o terminal `1 · Caixa 1`.
- [ ] O banco não responde de fora: a porta `5432` da VPS está fechada.
- [ ] `POSTGRES_ADMIN_PASSWORD` não está mais nas variáveis da API.

### 8. PDV apontando para a homologação

Em `apps/pdv`:

```bash
flutter run -d windows --dart-define=APP_ENV=homologation --dart-define=API_URL=https://hom-api.exemplo.com.br
```

Fora de desenvolvimento, o PDV recusa um endereço que não seja HTTPS.

## Antes de publicar a produção

A produção usa os mesmos passos, em um projeto próprio e com segredos próprios, mas depende destes itens:

- [ ] Login implementado, substituindo `DevUserGuard` e o seletor de usuário.
- [ ] Decisão sobre como publicar: manualmente pelo painel, sem o job automático.
- [ ] [Backup diário do banco](https://easypanel.io/docs/backups/database), com destino fora da VPS.
- [ ] Restauração testada: recupere um backup em um banco separado e confira os dados. Backup sem restauração testada não é garantia.
- [ ] Sem `ADMIN_INTERNAL_SECRET` nem seed: o seed se recusa a rodar em produção.

## Variáveis e segurança

- **Senhas no contêiner:** o `docker-entrypoint.sh` remove a senha de dono antes de iniciar a API, então o processo não a recebe. Quem tem acesso ao painel ou ao console do contêiner ainda consegue vê-la.
- **Variáveis no build:** o EasyPanel repassa as variáveis como argumentos de build. Os Dockerfiles não as declaram, para que não fiquem gravadas na imagem. Não acrescente `ARG` com segredos.
- **Uma instância:** o limite de tentativas fica em memória, então a API deve rodar com uma única réplica por enquanto.

## Problemas comuns

| O que aparece | O que fazer |
|---|---|
| `A variável APP_ENV precisa ser...` | Confira o valor de `APP_ENV` |
| `Configuração inválida: ...` | A mensagem lista as variáveis faltando ou curtas |
| `O banco recusou o acesso` | No primeiro deploy, defina `POSTGRES_ADMIN_PASSWORD`. Depois, confira `FARMAERP_MIGRATOR_PASSWORD` |
| `Falha ao preparar o banco` | Confira `DB_HOST` e os logs do banco. A versão anterior deve ser mantida |
| Retaguarda mostra `FA002` | `ADMIN_INTERNAL_SECRET` diferente entre `api` e `web` |
| Retaguarda mostra `FA001` | Confira `API_URL` e se a API está no ar |

Para testar as imagens localmente, sem o EasyPanel:

```bash
npm run test:images
```
