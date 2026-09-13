# FIAP Cloud Games - Orchestration

Ambiente local da plataforma FIAP Cloud Games, com Docker Compose e manifestos Kubernetes. Integra cadastro e autenticação de usuários, catálogo, compras, pagamentos simulados e notificações.

## Arquitetura

- Kong Gateway OSS 3.9.3 em modo tradicional, com PostgreSQL exclusivo.
- UsersAPI e CatalogAPI em .NET 10, cada uma com SQL Server próprio.
- MongoDB para detalhes opcionais dos jogos e Redis para cache de consultas individuais.
- RabbitMQ para eventos entre os serviços.
- PaymentsAPI para simulação de pagamentos.
- Notifications Function e Azurite no Docker; NotificationsAPI no Kubernetes.
- Prometheus e Grafana para métricas das APIs.

A entrada HTTP de UsersAPI e CatalogAPI passa pelo Kong. Os prefixos públicos são /identity e /catalog; internamente as APIs recebem /api. As três operações públicas são cadastro, login e recuperação de senha. As demais exigem JWT; autorização por perfil também é validada pelas APIs.

## Requisitos e organização

- Docker Desktop com containers Linux e Docker Compose.
- Para Kubernetes: cluster disponível, kubectl e armazenamento para os PVCs.
- .NET 10 SDK para executar os testes dos serviços.

Mantenha os repositórios lado a lado:

```text
Projetos/
  fiap-cloud-games-orchestration/
  fiap-cloud-games-users-api/
  fiap-cloud-games-catalog-api/
  fiap-cloud-games-payments-api/
  fiap-cloud-games-notifications-api/
  fiap-cloud-games-notifications-function/
```

O Compose usa contextos de build dos repositórios irmãos. Os manifestos Kubernetes usam imagens publicadas em um registry.

## Executar com Docker

Na raiz deste repositório:

```powershell
docker compose config --quiet
docker compose up -d --build
docker compose ps -a
```

A inicialização aplica migrations SQL e do Kong, configura Services, Routes e JWT pela Admin API e provisiona as filas de notificação. Os serviços de inicialização devem terminar com Exited (0). APIs, bancos, Gateway, Function e monitoração permanecem em execução.

Acompanhe os logs:

```powershell
docker compose logs -f users-api catalog-api payments-api notifications-function
docker compose logs --tail=100 kong kong-configure rabbitmq-topology
```

## Acessos locais

| Componente | Endereço |
| --- | --- |
| Kong proxy | http://localhost:8000 |
| Kong Admin API | http://localhost:8001 — somente loopback |
| Kong Manager | http://localhost:8002 — somente loopback |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |
| RabbitMQ Management | http://localhost:15672 |
| RabbitMQ AMQP | localhost:5672 |
| SQL Server Users | localhost,1433 |
| SQL Server Catalog | localhost,1434 |
| MongoDB | 127.0.0.1:27017 |
| Redis | 127.0.0.1:6379 |
| PaymentsAPI | http://localhost:5004/swagger |
| NotificationsAPI — perfil legado | http://localhost:5002/swagger |

UsersAPI e CatalogAPI não publicam portas no host. Function e Azurite ficam internos no ambiente integrado.

Credenciais de desenvolvimento local:

| Componente | Usuário | Senha padrão |
| --- | --- | --- |
| RabbitMQ | guest | guest |
| SQL Server | sa | Fcg@123456 |
| Grafana | admin | fcg-local-grafana |
| MongoDB do catálogo | fcg-catalog | fcg-local-mongo |
| Redis | default | fcg-local-redis |

Os bancos SQL são FiapCloudGamesUsers e FiapCloudGamesCatalog. MongoDB usa autenticação em FiapCloudGamesCatalog. Credenciais acadêmicas não devem ser usadas em ambientes publicados. Azurite utiliza uma conta fictícia, sem relação com uma conta Azure.

## Configuração

As variáveis e dependências de cada serviço estão no docker-compose.yml. Os parâmetros de autenticação JWT devem ser iguais em UsersAPI, CatalogAPI e Kong.

FCG_MONGODB_PASSWORD, FCG_MONGODB_ROOT_PASSWORD, FCG_REDIS_PASSWORD e FCG_GRAFANA_PASSWORD permitem substituir as senhas locais correspondentes. Alterar uma variável não troca automaticamente senhas já persistidas no MongoDB ou PostgreSQL; faça rotação no banco e atualize os consumidores sem excluir volumes.

Para reaplicar manualmente a configuração do Kong:

```powershell
.\kong\configure-kong.ps1
```

Em banco novo, informe FCG_JWT_SECRET ou o parâmetro -JwtSecret com o mesmo segredo das APIs. O configurador do Compose já recebe a configuração local. Alterações feitas no Kong Manager precisam ser refletidas no script para serem reproduzíveis.

## Usar a plataforma

1. Cadastre um usuário em POST http://localhost:8000/identity/users.
2. Faça login em POST /identity/auth/login.
3. Envie o token recebido em Authorization: Bearer TOKEN.
4. Consulte GET /catalog/games.
5. Compre um jogo em POST /catalog/library/games/purchase.
6. Consulte GET /catalog/library/games e acompanhe os logs da Function.

Cadastro:

```json
{
  "name": "Usuário de exemplo",
  "email": "usuario@example.com",
  "cpf": "11144477735",
  "birthDate": "1993-06-17",
  "password": "Senha@123",
  "confirmPassword": "Senha@123"
}
```

Compra:

```json
{
  "gameIds": ["GUID_DO_JOGO"]
}
```

A compra retorna HTTP 202 com orderId. PaymentsAPI publica o resultado; pagamentos Approved adicionam os jogos à biblioteca e geram uma notificação simulada. A atualização é assíncrona.

As migrations criam o administrador admin@email.com, CPF 52998224725, nascimento 1990-01-01 e perfil Administrator. Para definir uma senha local, use POST /identity/auth/forgot-password com esses dados e os campos newPassword e confirmNewPassword. Esse mecanismo de recuperação é acadêmico e não deve ser publicado sem proteção adequada.

## Notificações e filas

O Docker executa notifications-function por padrão. Cada fila de notificação deve ter um único consumidor:

- notifications-user-created-event
- notifications-payment-processed-event

O serviço rabbitmq-topology configura e verifica as filas e bindings sem remover mensagens. A Function não envia e-mails reais e o Azurite não cria recursos na Azure.

Para usar a NotificationsAPI em vez da Function:

```powershell
docker compose stop notifications-function
docker compose --profile legacy-notifications up -d notifications-api
```

Para retornar à Function:

```powershell
docker compose stop notifications-api
docker compose up -d notifications-function
```

Não habilite o perfil legado sem indicar o serviço: isso também inicia a Function padrão e faz os consumidores disputarem mensagens. Não execute outro host da Function no mesmo broker.

## Construir e publicar imagens

Na raiz da orquestração, após autenticar no Docker Hub:

```powershell
docker login
docker build --platform linux/amd64 -t maicaoxd/fiap-cloud-games-users-api:0.2.1 ../fiap-cloud-games-users-api
docker build --platform linux/amd64 -t maicaoxd/fiap-cloud-games-catalog-api:0.4.1 ../fiap-cloud-games-catalog-api
docker build --platform linux/amd64 -t maicaoxd/fiap-cloud-games-payments-api:0.1.1 ../fiap-cloud-games-payments-api
docker build --platform linux/amd64 -t maicaoxd/fiap-cloud-games-notifications-api:0.1.2 ../fiap-cloud-games-notifications-api
docker build --platform linux/amd64 -t maicaoxd/fiap-cloud-games-notifications-function:0.1.0 ../fiap-cloud-games-notifications-function
```

Publique as tags construídas:

```powershell
docker push maicaoxd/fiap-cloud-games-users-api:0.2.1
docker push maicaoxd/fiap-cloud-games-catalog-api:0.4.1
docker push maicaoxd/fiap-cloud-games-payments-api:0.1.1
docker push maicaoxd/fiap-cloud-games-notifications-api:0.1.2
docker push maicaoxd/fiap-cloud-games-notifications-function:0.1.0
```

Os comandos usam o namespace maicaoxd. Para outra conta, substitua o namespace também no Compose e nos manifestos. Use uma tag nova para cada versão; não sobrescreva releases anteriores. O Compose mantém contextos de build locais e tags versionadas. Para executar imagens já publicadas sem recompilar:

```powershell
docker compose pull
docker compose up -d --no-build
```

Publicar uma imagem não atualiza os Pods em execução. No Kubernetes, aplique os manifestos depois de disponibilizar as tags e observe as instruções de atualização dos Jobs.

## Kubernetes

Confirme o contexto antes de aplicar:

```powershell
kubectl config current-context
kubectl get nodes
kubectl apply -k .\k8s
kubectl get pods,jobs,services,pvc -n fiap-cloud-games
```

As imagens referenciadas pelos manifestos são:

```text
maicaoxd/fiap-cloud-games-users-api:0.2.1
maicaoxd/fiap-cloud-games-catalog-api:0.4.1
maicaoxd/fiap-cloud-games-payments-api:0.1.1
maicaoxd/fiap-cloud-games-notifications-api:0.1.2
```

Disponibilize essas imagens no registry ou no runtime dos nós. Alterações de código exigem build, publicação e atualização da tag nos Deployments e Jobs correspondentes.

```powershell
kubectl wait --for=condition=complete job/users-api-migration job/catalog-api-migration job/kong-migrations job/kong-configure -n fiap-cloud-games --timeout=600s
kubectl rollout status deployment/kong -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/catalog-api -n fiap-cloud-games --timeout=300s
```

Jobs concluídos não são executados novamente por kubectl apply. Ao atualizar o template de um Job, confirme sua conclusão e recrie somente o Job correspondente; não remova os bancos ou PVCs.

Kong proxy usa NodePort 30080. Se o provedor local não encaminhar essa porta, mantenha aberto:

```powershell
kubectl port-forward svc/kong-proxy 8005:8000 --address 127.0.0.1 -n fiap-cloud-games
```

Use http://localhost:8005 para as requisições. Prometheus e Grafana são acessados em terminais separados:

```powershell
kubectl port-forward svc/prometheus 9091:9090 --address 127.0.0.1 -n fiap-cloud-games
```

```powershell
kubectl port-forward svc/grafana 3001:3000 --address 127.0.0.1 -n fiap-cloud-games
```

Abra http://localhost:9091/targets e http://localhost:3001/d/fcg-apis. Services administrativos e bancos permanecem internos; volumes Docker e PVCs Kubernetes não compartilham dados. O Kubernetes executa NotificationsAPI, sem Function ou Azurite.

## Guias de configuração

- [Kong: Services, Routes, JWT e interface administrativa](kong/README.md)
- [Prometheus e Grafana: coleta, consultas e dashboard](observability/README.md)
- [MongoDB: contrato, configuração e consulta dos detalhes](mongodb/README.md)
- [Redis: cache, inspeção e invalidação](redis/README.md)

## Parar e solucionar problemas

```powershell
docker compose down
```

Esse comando preserva volumes. Não use down -v para uma parada normal: ele remove os dados persistidos. A remoção da base Kubernetes também pode excluir PVCs.

Para falhas de inicialização, consulte docker compose ps -a e os logs do serviço. No Kubernetes:

```powershell
kubectl logs job/catalog-api-migration -n fiap-cloud-games
kubectl logs job/kong-configure -n fiap-cloud-games
kubectl logs deployment/catalog-api -n fiap-cloud-games
```

- ImagePullBackOff: confira tag, acesso ao registry e disponibilidade da imagem.
- Porta ocupada: evite executar vários Composes usando as mesmas portas.
- HTTP 401: confira assinatura, expiração, emissor e configuração JWT.
- HTTP 403: confira o perfil do usuário e obtenha um novo token após alterações.
- Dashboard sem dados: confira os targets e gere requisições que alcancem as APIs. Requisições rejeitadas no Kong não entram nas métricas das APIs.
