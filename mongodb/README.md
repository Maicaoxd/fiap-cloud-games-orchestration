# MongoDB — catálogo expandido no Docker

## Responsabilidade

SQL Server continua sendo a fonte de jogos, preço, disponibilidade, pedidos e biblioteca. MongoDB guarda apenas detalhes opcionais, na coleção `FiapCloudGamesCatalog.game_details`. O `_id` é exatamente o `Game.Id` SQL, gravado como UUID BSON Standard (subtipo 4), não ObjectId. O índice único de `_id` já garante um documento por jogo.

Não há migrations SQL, transação entre bancos ou chave estrangeira SQL/Mongo. A aplicação verifica o jogo SQL antes de consultar/gravar detalhes. Jogos inativos e inexistentes continuam retornando 404. A listagem, o CRUD dos campos SQL e as compras não acessam Mongo nesta etapa. A desativação preserva o documento para histórico, mas impede sua consulta/atualização por esses endpoints.

## Subir e verificar

Na raiz da orquestração:

```powershell
docker compose config --quiet
docker compose build catalog-api
docker compose up -d catalog-mongodb catalog-api
docker compose ps
docker compose logs --tail=100 catalog-mongodb catalog-api
```

O Compose usa MongoDB Community `mongo:8.0.29`, volume `catalog-mongodb-data`, autenticação e nenhuma porta 27017 no host. O usuário `fcg-catalog` possui somente `readWrite` no banco do catálogo; a API não usa root. `init-catalog.js` é configuração de infraestrutura e roda apenas na primeira inicialização do volume.

Credenciais acadêmicas podem ser definidas por `FCG_MONGODB_PASSWORD` e `FCG_MONGODB_ROOT_PASSWORD` antes da primeira subida. Alterar essas variáveis depois não troca as senhas já persistidas: faça rotação no banco; não apague volumes para trocar senha. Produção exige gestão de segredos, backups e política de acesso.

Sem publicar portas, para inspecionar o banco:

```powershell
docker compose exec catalog-mongodb mongosh --username fcg-catalog --authenticationDatabase FiapCloudGamesCatalog FiapCloudGamesCatalog
```

Informe a senha quando solicitada. No mongosh:

```javascript
db.game_details.findOne({ _id: UUID("GUID-DO-JOGO") })
db.game_details.countDocuments({ _id: UUID("GUID-DO-JOGO") })
```

Nunca execute comandos de remoção em massa. O volume persiste em reinícios e em `docker compose down`, mas `down -v` remove dados.

## Gravar pelo Kong

Use um jogo ativo já cadastrado no SQL e JWT com role `Administrator`:

`PUT http://localhost:8000/catalog/games/{gameId}/details`

Headers: `Authorization: Bearer <token>` e `Content-Type: application/json`.

```json
{
  "developer": "Estudio Exemplo",
  "publisher": "Publicadora Exemplo",
  "genres": ["Action", "Adventure"],
  "platforms": ["Windows", "Linux"],
  "languages": ["pt-BR", "en-US"],
  "tags": ["Single-player"],
  "media": {
    "coverUrl": "https://cdn.example.com/game/cover.jpg",
    "screenshotUrls": ["https://cdn.example.com/game/screenshot-1.jpg"],
    "trailerUrl": null
  },
  "systemRequirements": {
    "windows": {
      "minimum": { "os": "Windows 10", "memoryGb": 8, "storageGb": 20 },
      "recommended": { "os": "Windows 11", "memoryGb": 16, "storageGb": 20 }
    }
  },
  "attributes": { "crossPlay": false, "maxPlayers": 1 }
}
```

PUT faz upsert, substituindo todos os campos de conteúdo, inclusive limpando campos omitidos. `{}` configura detalhes vazios; não exclui o documento. Arrays e dicionários ausentes/null viram vazios. `schemaVersion=1`, `createdAt` e `updatedAt` são controlados pelo servidor. O upsert é atômico e preserva `createdAt` na atualização. A resposta 200 contém `schemaVersion`, `content`, `createdAt` e `updatedAt`.

Limites: corpo até 64 KiB; developer/publisher até 150 caracteres; listas com itens não vazios até 100 caracteres (genres/platforms 30, languages/tags 50); até 20 screenshots com URLs HTTP/HTTPS até 2048 caracteres; até 20 plataformas com requisitos e valores inteiros não negativos de memória/armazenamento. Até 50 atributos: chaves até 80 caracteres sem ponto, $ ou caractere nulo; valores simples (texto até 500 caracteres, número finito, booleano, null) ou arrays de até 20 valores simples. Objetos/arrays aninhados e campos desconhecidos são rejeitados.

Retornos: 400 conteúdo inválido, 401 sem JWT/inválido, 403 não administrador, 404 jogo ausente/inativo, 413 corpo acima do limite e 503 Mongo indisponível. Falha de escrita nunca é reportada como sucesso. Não é necessário mudar as Routes do Kong: o prefixo protegido `/catalog` já inclui este endpoint.

## Consulta composta e falhas

`GET http://localhost:8000/catalog/games/{gameId}`, com JWT, mantém `gameId`, `title`, `description` e `price`, acrescentando:

- `detailsStatus: "available"`: `details` contém schemaVersion, content e datas.
- `detailsStatus: "notConfigured"`: jogo existente, sem documento; `details: null`.
- `detailsStatus: "unavailable"`: Mongo não respondeu; HTTP 200 com dados SQL e `details: null`, registrando warning sem credenciais.

Seleção de servidor/conexão/operação Mongo têm limite configurado de dois segundos. Cancelamento do cliente e erros inesperados de programação/serialização não são mascarados como ausência de detalhes. A readiness da API continua verificando SQL/RabbitMQ: Mongo é opcional para leitura e não impede os fluxos principais.

Para experimentar a falha em ambiente local, pare só `catalog-mongodb`, consulte um jogo e tente PUT; depois religue o banco com `docker compose start catalog-mongodb`. Não faça esse exercício em produção. No futuro Redis, respostas `unavailable` não devem ser cacheadas como detalhes definitivos.

## Estrutura e testes

CatalogAPI: contrato tipado e validação em Application/Games/Details, interface IGameDetailsRepository, adapter Mongo em Infrastructure/Persistence/Mongo, controller administrativo separado e composição em GetGameUseCase. MongoClient é singleton; não é aberta conexão Mongo para executar migrations SQL.

```powershell
dotnet test tests/CatalogAPI.Tests/CatalogAPI.Tests.csproj
```

Execute no repositório CatalogAPI. Os testes cobrem validação, normalização, BSON/UUID, estados de leitura, cancelamento, jogos ausentes/inativos, gravação e proteção administrativa. Esta entrega é Docker; Kubernetes ainda usa a imagem 0.2.0, sem Mongo. Não aplique a nova CatalogAPI no cluster antes de adicionar sua infraestrutura/configuração Mongo.

Referências: [UUID no driver .NET](https://www.mongodb.com/docs/drivers/csharp/current/serialization/guids/), [configuração da conexão](https://www.mongodb.com/docs/drivers/csharp/current/connect/connection-options/), [notas da versão 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0).

## Validação realizada

- 262 testes aprovados: Users 155, Catalog 94 (68 existentes + 26 novos), Payments 8, Notifications 5.
- Imagem local da CatalogAPI compilada e migrations SQL concluídas.
- Pelo Kong: criação do jogo SQL, GET sem documento, dois PUTs sem duplicidade, consulta composta, preservação de createdAt e limpeza de campos omitidos.
- Status 401/403/400/404/413 comprovados; jogos inativos rejeitam consulta/gravação de detalhes.
- Documento único UUID BSON, sem duplicação de preço; persistência após reiniciar Mongo.
- Queda simulada: GET 200/unavailable em aproximadamente dois segundos; PUT 503; recuperação sem modificar os detalhes.
- Jogo e documento temporários removidos ao final, sem alterações nos jogos existentes. Nenhum script auxiliar de teste ou Job foi adicionado.
