# FIAP Cloud Games - Orchestration

Repositorio de orquestracao local da Fase 2 do Tech Challenge FIAP Cloud Games.

Este repositorio nao contem codigo C#. Ele centraliza a infraestrutura local para subir os microsservicos e dependencias com Docker Compose.

## Repositorios esperados

A estrutura local esperada e que os repositorios fiquem lado a lado:

```text
C:\Projetos\FIAP\Projetos\
  fiap-cloud-games-orchestration\
  fiap-cloud-games-users-api\
  fiap-cloud-games-notifications-api\
```

O `docker-compose.yml` deste repositorio usa `build.context` apontando para os repositorios irmaos:

```text
../fiap-cloud-games-users-api
../fiap-cloud-games-notifications-api
```

## Servicos

O compose sobe:

- `rabbitmq`: broker de mensageria com Management UI.
- `users-sqlserver`: banco SQL Server da UsersAPI.
- `users-api`: microsservico de usuarios.
- `notifications-api`: microsservico de notificacoes.

## Portas

| Servico | Porta local | Porta container | URL |
|---|---:|---:|---|
| UsersAPI | `5001` | `8080` | `http://localhost:5001/swagger` |
| NotificationsAPI | `5002` | `8080` | `http://localhost:5002/swagger` |
| RabbitMQ AMQP | `5672` | `5672` | `amqp://localhost:5672` |
| RabbitMQ Management | `15672` | `15672` | `http://localhost:15672` |
| SQL Server Users | `1433` | `1433` | `localhost,1433` |

RabbitMQ Management:

```text
usuario: guest
senha: guest
```

SQL Server local:

```text
Server: localhost,1433
User: sa
Password: Fcg@123456
Database: FiapCloudGamesUsers
```

## Arquivo .env.example

O arquivo .env.example documenta portas e credenciais locais usadas no compose. Nesta primeira versao, o docker-compose.yml ja esta autocontido, entao voce nao precisa criar .env para subir o ambiente.

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
docker compose logs -f notifications-api
```

## Banco e migrations

No Docker Compose, a UsersAPI recebe:

```text
Database__ApplyMigrationsOnStartup=true
```

Isso faz a UsersAPI aplicar as migrations automaticamente ao iniciar no ambiente local Docker.

No `appsettings.json` da UsersAPI, essa opcao fica `false` por padrao. Assim evitamos que a aplicacao aplique migration automaticamente fora do ambiente controlado de desenvolvimento.

## Health checks

UsersAPI:

```text
http://localhost:5001/health/live
http://localhost:5001/health
http://localhost:5001/health/ready
```

O readiness da UsersAPI valida:

- SQL Server
- RabbitMQ

NotificationsAPI:

```text
http://localhost:5002/health/live
http://localhost:5002/health
http://localhost:5002/health/ready
```

O readiness da NotificationsAPI valida:

- RabbitMQ

## Teste do fluxo Users -> Notifications

1. Suba tudo:

```powershell
docker compose up --build
```

2. Abra o Swagger da UsersAPI:

```text
http://localhost:5001/swagger
```

3. Cadastre um usuario no endpoint `POST /api/users`.

Exemplo via PowerShell:

```powershell
curl -X POST "http://localhost:5001/api/users" `
  -H "Content-Type: application/json" `
  -d '{
    "name": "Maicon Guedes",
    "email": "maicon@email.com",
    "cpf": "529.982.247-25",
    "birthDate": "1993-06-17",
    "password": "Senha@123",
    "confirmPassword": "Senha@123"
  }'
```

4. Veja os logs da NotificationsAPI:

```powershell
docker compose logs -f notifications-api
```

Log esperado:

```text
E-mail de boas-vindas enviado para Maicon Guedes (maicon@email.com).
```

## Parar ambiente

Parar containers mantendo volumes:

```powershell
docker compose down
```

Parar e apagar volumes, incluindo banco SQL Server:

```powershell
docker compose down -v
```

## Problemas comuns

### Porta ja em uso

Se `1433`, `5672`, `15672`, `5001` ou `5002` ja estiverem ocupadas, o compose pode falhar.

Verifique containers rodando:

```powershell
docker ps
```

### UsersAPI unhealthy

Confira se SQL Server e RabbitMQ estao saudaveis:

```powershell
docker compose ps
docker compose logs users-sqlserver
docker compose logs rabbitmq
```

### Banco sem tabelas

Confira os logs da UsersAPI. Ela deve registrar a aplicacao das migrations no startup quando `Database__ApplyMigrationsOnStartup=true`.

```powershell
docker compose logs users-api
```

### NotificationsAPI nao recebe evento

Confira se ela esta conectada no RabbitMQ e se existe fila criada no Management UI:

```text
http://localhost:15672
```

Quando o consumer funciona, a mensagem pode nao ficar parada na fila. Ela entra, e logo depois sai com ACK.

