# FIAP Cloud Games - Orchestration

Repositorio de orquestracao local do Tech Challenge FIAP Cloud Games, com Gateway da Fase 3.

Este repositorio centraliza Docker Compose e Kubernetes para subir a aplicacao completa com os quatro microsservicos, RabbitMQ e bancos SQL Server.

## Gateway da Fase 3

Compose e Kubernetes incluem Kong Gateway OSS com PostgreSQL e migrations. A entrada de UsersAPI e CatalogAPI usa os prefixos `/identity` e `/catalog`: `http://localhost:8000` no Docker e `http://localhost:30080` no Kubernetes Docker Desktop. As portas diretas `5001` e `5003` nao sao mais publicadas. Kong Manager esta disponivel somente no Compose.

Consulte [configuracao e validacao do Kong](kong/README.md) para Services, Routes, JWT e scripts idempotentes.

## Observabilidade no Docker

UsersAPI e CatalogAPI expoem `/metrics` internamente. O Prometheus coleta as duas APIs; Grafana carrega a fonte Prometheus e o dashboard `FIAP Cloud Games - APIs` por arquivos versionados, com sete paineis e filtro por API. As configuracoes podem ser exploradas e editadas pela interface.

- Prometheus: `http://localhost:9090`.
- Grafana: `http://localhost:3000` (login local inicial `admin` / `fcg-local-grafana`).

Consulte [configuracao e uso](observability/README.md). Os manifestos de observabilidade Kubernetes estao em `k8s/observability`; antes de aplica-los, disponibilize as imagens instrumentadas 0.2.0 das APIs no cluster ou no registry.

## Repositorios esperados

A estrutura local esperada e que os repositorios fiquem lado a lado:

```text
C:\Projetos\FIAP\Projetos\
  fiap-cloud-games-orchestration\
  fiap-cloud-games-users-api\
  fiap-cloud-games-catalog-api\
  fiap-cloud-games-payments-api\
  fiap-cloud-games-notifications-api\
```

O `docker-compose.yml` usa `build.context` apontando para esses repositorios irmaos.

## Servicos

O compose sobe:

- `kong-database`: PostgreSQL exclusivo do Gateway, persistente.
- `kong-migrations`: inicializa ou atualiza o schema do Kong.
- `kong`: proxy, Admin API e Manager locais.
- `rabbitmq`: broker de mensageria com Management UI.
- `users-sqlserver`: banco SQL Server da UsersAPI.
- `catalog-sqlserver`: banco SQL Server da CatalogAPI.
- `users-api-migrator`: aplica migrations da UsersAPI.
- `catalog-api-migrator`: aplica migrations da CatalogAPI.
- `users-api`: cadastro, login, JWT e publicacao de `UserCreatedEvent`.
- `catalog-api`: CRUD de jogos, compra e consumo de `PaymentProcessedEvent`.
- `payments-api`: consumo de `OrderPlacedEvent` e publicacao de `PaymentProcessedEvent`.
- `notifications-api`: consumo de `UserCreatedEvent` e `PaymentProcessedEvent`.

## Portas

| Servico                        |   Porta local | Porta container | URL                                |
| ------------------------------ | ------------: | --------------: | ---------------------------------- |
| Kong proxy                     |        `8000` |          `8000` | `http://localhost:8000`            |
| Kong Admin API (somente local) |        `8001` |          `8001` | `http://localhost:8001`            |
| Kong Manager (somente local)   |        `8002` |          `8002` | `http://localhost:8002`            |
| UsersAPI                       | nao publicada |          `8080` | interna: `http://users-api:8080`   |
| NotificationsAPI               |        `5002` |          `8080` | `http://localhost:5002/swagger`    |
| CatalogAPI                     | nao publicada |          `8080` | interna: `http://catalog-api:8080` |
| PaymentsAPI                    |        `5004` |          `8080` | `http://localhost:5004/swagger`    |
| RabbitMQ AMQP                  |        `5672` |          `5672` | `amqp://localhost:5672`            |
| RabbitMQ Management            |       `15672` |         `15672` | `http://localhost:15672`           |
| SQL Server Users               |        `1433` |          `1433` | `localhost,1433`                   |
| SQL Server Catalog             |        `1434` |          `1433` | `localhost,1434`                   |

RabbitMQ Management:

```text
usuario: guest
senha: guest
```

SQL Server local:

```text
User: sa
Password: Fcg@123456
Users database:   FiapCloudGamesUsers
Catalog database: FiapCloudGamesCatalog
```

## Subir ambiente completo

Na raiz deste repositorio:

```powershell
docker compose up --build
```

Para rodar em background:

```powershell
docker compose up --build -d
```

Depois de subir o ambiente, aplique a configuracao do Gateway:

```powershell
.\kong\configure-kong.ps1
```

Em um PostgreSQL novo, o script exige o segredo JWT por `FCG_JWT_SECRET` ou `-JwtSecret`, igual ao das APIs. Veja `kong/README.md`.

Ver containers:

```powershell
docker compose ps
```

Ver logs:

```powershell
docker compose logs -f users-api
docker compose logs -f catalog-api
docker compose logs -f payments-api
docker compose logs -f notifications-api
```

## Banco e migrations no Docker Compose

O compose executa migrations automaticamente antes de subir UsersAPI e CatalogAPI:

```text
users-sqlserver saudavel -> users-api-migrator -> users-api
catalog-sqlserver saudavel -> catalog-api-migrator -> catalog-api
```

Os migrators usam as mesmas imagens das APIs e executam:

```powershell
dotnet UsersAPI.dll --migrate
dotnet CatalogAPI.dll --migrate
```

A migration da UsersAPI tambem cria o administrador inicial:

```text
e-mail: admin@email.com
CPF: 52998224725
data de nascimento: 1990-01-01
role: Administrator
```

Para definir uma senha local, use `POST /identity/auth/forgot-password` pelo Gateway com esses dados de recuperacao.

## Health checks

```text
UsersAPI:         http://users-api:8080/health (rede Docker)
NotificationsAPI: http://localhost:5002/health
CatalogAPI:       http://catalog-api:8080/health (rede Docker)
PaymentsAPI:      http://localhost:5004/health
```

O readiness de UsersAPI e CatalogAPI valida SQL Server e RabbitMQ.
O readiness de PaymentsAPI e NotificationsAPI valida RabbitMQ.

UsersAPI e CatalogAPI nao possuem health checks publicados sem autenticacao pelo Gateway. O status administrativo local do Kong esta em `http://localhost:8001/status`.

## Fluxo completo esperado

```text
UsersAPI publica UserCreatedEvent
  -> NotificationsAPI consome e simula e-mail de boas-vindas

CatalogAPI publica OrderPlacedEvent
  -> PaymentsAPI consome e publica PaymentProcessedEvent
  -> CatalogAPI consome e adiciona jogos na biblioteca se Approved
  -> NotificationsAPI consome e simula e-mail de confirmacao se Approved
```

## Kubernetes

Os manifests ficam em `k8s/` e usam `Kustomization` para consolidar infraestrutura e aplicacoes.

Os Jobs de migrations de UsersAPI e CatalogAPI possuem um `initContainer` que aguarda uma consulta `SELECT 1` autenticada no SQL Server antes de iniciar o migrator. A senha vem do Secret do respectivo banco. O limite total de cada Job e 600 segundos, incluindo downloads e essa espera, para acomodar uma primeira subida sem imagens em cache.

Aplicar:

```powershell
# Recria somente o configurador para reaplicar mudancas de Routes/plugins.
kubectl delete job kong-configure -n fiap-cloud-games --ignore-not-found
kubectl apply -k .\k8s
kubectl wait --for=condition=complete job/kong-migrations -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/kong -n fiap-cloud-games --timeout=300s
kubectl wait --for=condition=complete job/kong-configure -n fiap-cloud-games --timeout=600s
```

UsersAPI e CatalogAPI permanecem ClusterIP. Kong Admin e PostgreSQL tambem sao internos; somente `kong-proxy` e NodePort `30080`. O ConfigMap do script e gerado diretamente de `kong/`, sem copia do configurador. Consulte [procedimento Kubernetes](kong/README.md#kubernetes).

Validar recursos:

```powershell
kubectl get pods -n fiap-cloud-games
kubectl get services -n fiap-cloud-games
kubectl get jobs -n fiap-cloud-games
```

Ver logs:

```powershell
kubectl logs deployment/users-api -n fiap-cloud-games
kubectl logs deployment/catalog-api -n fiap-cloud-games
kubectl logs deployment/payments-api -n fiap-cloud-games
kubectl logs deployment/notifications-api -n fiap-cloud-games
```

Entrada da aplicacao:

```powershell
# Alternativa ao NodePort, sempre passando pelo Gateway:
kubectl port-forward svc/kong-proxy 8000:8000 -n fiap-cloud-games
```

Expor RabbitMQ Management:

```powershell
kubectl port-forward svc/rabbitmq 15672:15672 -n fiap-cloud-games
```

## Docker Hub

Os manifests Kubernetes usam imagens do Docker Hub:

```text
maicaoxd/fiap-cloud-games-users-api:0.2.0
maicaoxd/fiap-cloud-games-catalog-api:0.2.0
maicaoxd/fiap-cloud-games-payments-api:0.1.0
maicaoxd/fiap-cloud-games-notifications-api:0.1.1
```

Sempre que alterar codigo de uma API usada pelo Kubernetes, gere uma nova tag, faca push e atualize o manifesto correspondente.

## Parar ambiente Docker

Parar containers mantendo volumes:

```powershell
docker compose down
```

Apagar definitivamente todos os bancos locais (SQL Server e PostgreSQL do Kong); nao usar para uma parada normal:

```powershell
docker compose down -v
```

## Problemas comuns

### Porta ja em uso

Se `1433`, `1434`, `5672`, `15672`, `8000`, `8001`, `8002`, `5002` ou `5004` ja estiverem ocupadas, o compose pode falhar.

### API unhealthy

Confira dependencias e logs:

```powershell
docker compose ps
docker compose logs rabbitmq
docker compose logs users-sqlserver
docker compose logs catalog-sqlserver
```

### Job de migration falhou no Kubernetes

Veja os logs do job:

```powershell
kubectl logs job/users-api-migration -n fiap-cloud-games
kubectl logs job/catalog-api-migration -n fiap-cloud-games
```

Se precisar recriar um Job ja concluido:

```powershell
kubectl delete job users-api-migration catalog-api-migration -n fiap-cloud-games
kubectl apply -k .\k8s
```
