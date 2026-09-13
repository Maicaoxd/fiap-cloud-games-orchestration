# Kong Gateway OSS — Docker e Kubernetes

Kong `3.9.3` em modo tradicional, com PostgreSQL `16-alpine` exclusivo e volume persistente. A configuracao e aplicada pela Admin API; nao utiliza DB-less.

## Acessos

- Proxy: `http://localhost:8000`
- Admin API: `http://localhost:8001`, publicada somente em `127.0.0.1`.
- Kong Manager: `http://localhost:8002`, publicado somente em `127.0.0.1`.
- UsersAPI e CatalogAPI: somente na rede Docker, porta interna `8080`; sem portas host `5001` e `5003`.

PaymentsAPI publica uma porta operacional de desenvolvimento. NotificationsAPI publica sua porta somente no perfil legado. SQL Server e RabbitMQ mantêm acessos locais para inspeção.

## Services e Routes

Dois Services: `users-api` e `catalog-api`, apontando para os respectivos containers com caminho-base `/api`.

| Route                           | Metodo | Caminho publico                | Politica                      |
| ------------------------------- | ------ | ------------------------------ | ----------------------------- |
| identity-public-registration    | POST   | /identity/users                | Publica, somente esse caminho |
| identity-public-login           | POST   | /identity/auth/login           | Publica, somente esse caminho |
| identity-public-forgot-password | POST   | /identity/auth/forgot-password | Publica, somente esse caminho |
| identity-protected              | Todos  | /identity e seus subcaminhos   | JWT obrigatorio               |
| catalog-protected               | Todos  | /catalog e seus subcaminhos    | JWT obrigatorio               |

As rotas publicas usam regex terminada em `$`, aceitando uma barra final opcional. Assim, `/identity/users/invite` ou `/identity/auth/login/extra` nao sao publicos. Regex de maior prioridade e metodo POST tornam as excecoes publicas mais especificas que o fallback protegido.

O router `traditional_compatible` nao suporta lookahead. Por isso, cada rota publica usa o plugin OSS `request-transformer` para substituir a URI por seu caminho interno exato (`/api/users`, `/api/auth/login` ou `/api/auth/forgot-password`). Nelas, `strip_path=false`; o plugin determina a URI final.

Nos fallbacks protegidos, `strip_path=true` remove o prefixo `/identity/` ou `/catalog/`, e o Service acrescenta `/api`. Exemplo: `/catalog/games/123` chega como `/api/games/123`. Os limites de segmento impedem que `/identityevil` ou `/catalogevil` sejam encaminhados.

Os antigos aliases publicos `/api/...` nao existem. Swagger e health checks nao tem rotas publicas sem autenticacao.

## JWT

- Consumer: `fiap-cloud-games`, representando o emissor, nao um usuario individual.
- Credencial: chave `FiapCloudGames`, algoritmo HS256.
- Plugins JWT somente nas duas Routes protegidas, sem restricao por Consumer.
- Identificacao pela claim `iss`; verificacao adicional de `exp`.
- Token somente pelo header `Authorization: Bearer TOKEN`, nao por query string ou cookie.
- APIs continuam validando assinatura, audiencia, identidade, expiracao e roles.

Todo novo endpoint em `/identity/...` e `/catalog/...` exige JWT no Gateway por padrao, inclusive POST. Se for publico, precisa de uma excecao explicita no script.

O JWT executa tambem em preflight. O acesso de um frontend em outra origem exige configuração explícita de CORS/OPTIONS; não existe liberação automática de OPTIONS.

## Configurar pela interface

Abra http://localhost:8002 e selecione o workspace padrão. Os nomes dos menus permanecem em inglês na interface do Kong.

1. Em Gateway Services, abra users-api. A URL de destino é http://users-api:8080/api. Para catalog-api, use http://catalog-api:8080/api.
2. Em Routes, consulte as cinco rotas da tabela. Cada Route referencia um Service e define como a requisição do cliente será reconhecida.
3. Para uma rota pública, use POST e o caminho regex exato (por exemplo, ~/identity/auth/login/?$), regex_priority=100 e Strip Path desabilitado.
4. Na rota pública, configure request-transformer, Replace > URI com /api/auth/login. Para cadastro e recuperação, use /api/users e /api/auth/forgot-password.
5. Nas rotas protegidas, use os paths ~/identity(?:/|$) ou ~/catalog(?:/|$), Strip Path habilitado e nenhuma restrição por verbo. O prefixo removido é substituído pelo caminho /api do Service.
6. Em Plugins das rotas protegidas, confira jwt com key_claim_name=iss, claims_to_verify contendo exp e leitura de token somente pelo header Authorization.
7. Em Consumers, confira fiap-cloud-games e a credencial JWT HS256 com key=FiapCloudGames e o mesmo segredo das APIs.

Evite criar cópias das entidades existentes. Alterações pela interface não atualizam o script versionado: registre a mesma configuração nele para reproduzir o ambiente.

## Aplicar configuracao

Na raiz do repositorio:

```powershell
docker compose up -d kong-database kong-migrations kong
.\kong\configure-kong.ps1
```

Em banco novo, informe o mesmo segredo usado pelas APIs, preferencialmente por variavel de ambiente `FCG_JWT_SECRET`. Alternativamente:

```powershell
.\kong\configure-kong.ps1 -JwtSecret 'SEGREDO_IGUAL_AO_DAS_APIS'
```

Em banco existente, o script preserva Consumer, credencial e IDs dos plugins JWT. Um segredo diferente causa erro; rotacao nao e feita implicitamente. O segredo nunca aparece no resumo do script.

O script gerencia dois Services, cinco Routes, tres plugins de reescrita e dois plugins JWT. Remove somente a Route legada conhecida `identity-public`; nao apaga entidades administrativas nao relacionadas. Alteracoes manuais pelo Manager precisam ser refletidas no script, pois a proxima execucao reconcilia os campos gerenciados.

## Consultar estado e logs

```powershell
docker compose ps -a
docker compose logs kong
```

Credenciais locais sao academicas. Producao exige gestao de segredos, rotacao e protecao adicional das interfaces administrativas.

## Kubernetes

O `k8s/kustomization.yaml` inclui PostgreSQL/PVC, Job de migrations, Kong, Services administrativos internos e Job configurador. `kong/kustomization.yaml` gera o ConfigMap diretamente do configurador desta pasta, com hash de conteudo. Nao existe uma segunda copia do script para manter.

O configurador usa `-UpstreamPort 80`, pois os Services das APIs usam porta 80 (containers continuam em 8080). O segredo vem de `users-api-secret`, chave `Jwt__Secret`; mantenha o segredo da CatalogAPI igual. O Job preserva a credencial existente e falha se encontrar segredo divergente.

```powershell
kubectl delete job kong-configure -n fiap-cloud-games --ignore-not-found
kubectl apply -k .\k8s
kubectl wait --for=condition=complete job/kong-migrations -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/kong -n fiap-cloud-games --timeout=300s
kubectl wait --for=condition=complete job/kong-configure -n fiap-cloud-games --timeout=600s
kubectl logs job/kong-configure -n fiap-cloud-games
```

O proxy usa NodePort 30080. No Docker Desktop, a disponibilidade em localhost depende do provedor; se não responder, encaminhe o Service com o comando abaixo:

```powershell
kubectl port-forward svc/kong-proxy 8005:8000 --address 127.0.0.1 -n fiap-cloud-games
```

Use http://localhost:8005 enquanto o terminal estiver aberto. Kong Admin e PostgreSQL sao ClusterIP; Manager desativado no cluster. UsersAPI e CatalogAPI tambem sao ClusterIP, sem NodePort/LoadBalancer. ClusterIP nao e isolamento entre pods: producao exige politicas de rede e controle de acesso ao cluster.

Consultar os Services do cluster:

```powershell
kubectl get services -n fiap-cloud-games
```

Reaplicar um Job concluido nao o executa novamente. Por isso os comandos recriam somente `kong-configure`; nao removem PVCs, bancos, consumers ou credenciais. Mudancas em imagens/manifesto do Job de migrations exigem recriar somente esse Job, apos backup e planejamento de upgrade. ConfigMaps antigos com hash podem ser removidos individualmente depois de confirmar que nenhum Pod/Job os referencia; nao use prune generico no namespace.
