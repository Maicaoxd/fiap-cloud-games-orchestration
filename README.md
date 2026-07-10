# FIAP Cloud Games - Orchestration

Repositorio de orquestracao local da Fase 2 do Tech Challenge FIAP Cloud Games.

Este repositorio centraliza Docker Compose e Kubernetes para subir a aplicacao completa com os quatro microsservicos, RabbitMQ e bancos SQL Server.

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

| Servico | Porta local | Porta container | URL |
|---|---:|---:|---|
| UsersAPI | `5001` | `8080` | `http://localhost:5001/swagger` |
| NotificationsAPI | `5002` | `8080` | `http://localhost:5002/swagger` |
| CatalogAPI | `5003` | `8080` | `http://localhost:5003/swagger` |
| PaymentsAPI | `5004` | `8080` | `http://localhost:5004/swagger` |
| RabbitMQ AMQP | `5672` | `5672` | `amqp://localhost:5672` |
| RabbitMQ Management | `15672` | `15672` | `http://localhost:15672` |
| SQL Server Users | `1433` | `1433` | `localhost,1433` |
| SQL Server Catalog | `1434` | `1433` | `localhost,1434` |

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

Para definir uma senha local, use o endpoint `POST /api/auth/forgot-password` da UsersAPI com esses dados de recuperacao.

## Health checks

```text
UsersAPI:         http://localhost:5001/health
NotificationsAPI: http://localhost:5002/health
CatalogAPI:       http://localhost:5003/health
PaymentsAPI:      http://localhost:5004/health
```

O readiness de UsersAPI e CatalogAPI valida SQL Server e RabbitMQ.
O readiness de PaymentsAPI e NotificationsAPI valida RabbitMQ.

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

Aplicar:

```powershell
kubectl apply -k .\k8s
```

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

Expor uma API localmente:

```powershell
kubectl port-forward svc/users-api 5001:80 -n fiap-cloud-games
kubectl port-forward svc/catalog-api 5003:80 -n fiap-cloud-games
kubectl port-forward svc/payments-api 5004:80 -n fiap-cloud-games
kubectl port-forward svc/notifications-api 5002:80 -n fiap-cloud-games
```

Expor RabbitMQ Management:

```powershell
kubectl port-forward svc/rabbitmq 15672:15672 -n fiap-cloud-games
```

## Docker Hub

Os manifests Kubernetes usam imagens do Docker Hub:

```text
maicaoxd/fiap-cloud-games-users-api:0.1.1
maicaoxd/fiap-cloud-games-catalog-api:0.1.0
maicaoxd/fiap-cloud-games-payments-api:0.1.0
maicaoxd/fiap-cloud-games-notifications-api:0.1.0
```

Sempre que alterar codigo de uma API usada pelo Kubernetes, gere uma nova tag, faca push e atualize o manifesto correspondente.

## Parar ambiente Docker

Parar containers mantendo volumes:

```powershell
docker compose down
```

Parar e apagar volumes, incluindo bancos SQL Server:

```powershell
docker compose down -v
```

## Problemas comuns

### Porta ja em uso

Se `1433`, `1434`, `5672`, `15672`, `5001`, `5002`, `5003` ou `5004` ja estiverem ocupadas, o compose pode falhar.

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
