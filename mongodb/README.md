# MongoDB — catálogo expandido no Docker e Kubernetes

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

O Compose usa MongoDB Community `mongo:8.0.29`, volume `catalog-mongodb-data` e autenticação. A porta `127.0.0.1:27017` permite conexão local pelo Compass, sem acesso pela rede externa. Use `mongodb://fcg-catalog:fcg-local-mongo@127.0.0.1:27017/FiapCloudGamesCatalog?authSource=FiapCloudGamesCatalog` com a senha acadêmica padrão; se mudou a senha, configure as credenciais correspondentes no Compass. O usuário `fcg-catalog` possui somente `readWrite` no banco do catálogo; a API não usa root. `init-catalog.js` é configuração de infraestrutura e roda apenas na primeira inicialização do volume.

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

Execute no repositório CatalogAPI. Os testes cobrem validação, normalização, BSON/UUID, estados de leitura, cancelamento, jogos ausentes/inativos, gravação e proteção administrativa. Os manifestos Kubernetes agora usam CatalogAPI 0.3.0 e incluem sua infraestrutura/configuração Mongo.

Referências: [UUID no driver .NET](https://www.mongodb.com/docs/drivers/csharp/current/serialization/guids/), [configuração da conexão](https://www.mongodb.com/docs/drivers/csharp/current/connect/connection-options/), [notas da versão 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0).

## Validação realizada no Docker

- 262 testes aprovados: Users 155, Catalog 94 (68 existentes + 26 novos), Payments 8, Notifications 5.
- Imagem local da CatalogAPI compilada e migrations SQL concluídas.
- Pelo Kong: criação do jogo SQL, GET sem documento, dois PUTs sem duplicidade, consulta composta, preservação de createdAt e limpeza de campos omitidos.
- Status 401/403/400/404/413 comprovados; jogos inativos rejeitam consulta/gravação de detalhes.
- Documento único UUID BSON, sem duplicação de preço; persistência após reiniciar Mongo.
- Queda simulada: GET 200/unavailable em aproximadamente dois segundos; PUT 503; recuperação sem modificar os detalhes.
- Jogo e documento temporários removidos ao final, sem alterações nos jogos existentes. Nenhum script auxiliar de teste ou Job foi adicionado.

## Kubernetes — publicar, aplicar e testar

Os recursos ficam em `k8s/catalog-mongodb` e são incluídos pelo Kustomize principal. A ConfigMap é gerada diretamente de `mongodb/init-catalog.js`, com hash no nome; o Deployment monta esse mesmo arquivo. Não há Job extra de configuração ou teste Mongo.

O Mongo é uma instância única acadêmica, sem replica set/alta disponibilidade. Usa estratégia Recreate para evitar dois pods disputando o PVC ReadWriteOnce, disco de 2 GiB, requests 100m/256 MiB e limites 1 CPU/1 GiB. O cache WiredTiger fica limitado a 0.25 GB, abaixo do limite do container, conforme a [orientação oficial para containers](https://www.mongodb.com/docs/v8.0/core/wiredtiger/). Startup/liveness verificam a porta; readiness exige autenticação do usuário da aplicação e ping.

A senha da API vem diretamente da chave FCG_MONGODB_PASSWORD do Secret catalog-mongodb-secret; a API não recebe as credenciais root. O Secret versionado é acadêmico e deve ser substituído em produção. O script cria o usuário somente no primeiro uso do PVC. Mudanças de senha no Secret não fazem rotação no banco; mudanças posteriores na senha também exigem reinício da API, pois env vars não são atualizadas em pods existentes. Não delete o PVC para aplicar alterações de configuração.

### 1. Publicar a CatalogAPI

Na raiz da orquestração:

```powershell
docker build -t maicaoxd/fiap-cloud-games-catalog-api:0.3.0 ../fiap-cloud-games-catalog-api
docker push maicaoxd/fiap-cloud-games-catalog-api:0.3.0
```

UsersAPI permanece em 0.2.0. Não reutilize 0.2.0 para código Mongo. Deployment e Job migrador da CatalogAPI usam a mesma versão 0.3.0; as migrations SQL em si não mudaram.

### 2. Conferir e aplicar

Ative Kubernetes no Docker Desktop e espere o cluster ficar disponível. Só selecione docker-desktop se ele aparecer na lista:

```powershell
kubectl config get-contexts
kubectl config use-context docker-desktop
kubectl get nodes
```

Sem um contexto configurado, kubectl pode tentar localhost:8080; isso não é erro do Mongo.

Para um ambiente novo:

```powershell
kubectl apply -k k8s/
```

Para um ambiente já existente, a atualização do template de um Job é imutável. Confira o Job anterior:

```powershell
kubectl get job catalog-api-migration -n fiap-cloud-games
```

Se já estiver concluído, remova somente esse Job (não o banco/PVC) e aplique:

```powershell
kubectl delete job catalog-api-migration -n fiap-cloud-games --ignore-not-found
kubectl apply -k k8s/
```

Se estiver em execução, aguarde sua conclusão antes da remoção. Esta etapa não altera Kong nem seus Jobs. Não precisa recriar kong-configure em um cluster já configurado só para adicionar Mongo.

### 3. Verificar

```powershell
kubectl rollout status deployment/catalog-mongodb -n fiap-cloud-games --timeout=300s
kubectl wait --for=condition=complete job/catalog-api-migration -n fiap-cloud-games --timeout=600s
kubectl rollout status deployment/catalog-api -n fiap-cloud-games --timeout=300s
kubectl get pods,services,pvc -n fiap-cloud-games
kubectl logs deployment/catalog-mongodb -n fiap-cloud-games --tail=100
kubectl logs deployment/catalog-api -n fiap-cloud-games --tail=100
```

Espere Mongo Ready, PVC Bound e CatalogAPI Ready. Service catalog-mongodb é ClusterIP na porta 27017, sem NodePort/LoadBalancer. O volume Docker e o PVC Kubernetes são independentes: jogos/detalhes cadastrados no Docker não aparecem automaticamente no cluster.

Para testar pelo mesmo Gateway, se NodePort não responder, use uma porta que não conflite com o Kong Docker:

```powershell
kubectl port-forward svc/kong-proxy 8005:8000 -n fiap-cloud-games
```

No Postman, use http://localhost:8005. Faça login em /identity/auth/login para obter o JWT daquele ambiente; crie/consulte um jogo do cluster, grave PUT /catalog/games/{gameId}/details com token Administrator e confira GET /catalog/games/{gameId}. Details deve voltar como available.

Para inspecionar o documento sem expor o banco:

```powershell
kubectl exec -it deployment/catalog-mongodb -n fiap-cloud-games -- mongosh --username fcg-catalog --authenticationDatabase FiapCloudGamesCatalog FiapCloudGamesCatalog
```

Informe a senha interativamente e consulte db.game_details.findOne({_id: UUID("GUID-DO-JOGO")}).

Para parar só o Mongo sem perder dados: kubectl scale deployment/catalog-mongodb --replicas=0 -n fiap-cloud-games. Nesse período, GET de jogo SQL ativo retorna unavailable e PUT retorna 503. Religue com --replicas=1. Para verificar persistência, faça rollout restart deployment/catalog-mongodb e aguarde rollout status: o mesmo documento deve continuar disponível. Não execute kubectl delete -k k8s/ se quiser preservar PVCs; isso pode excluir os dados.

### Estado da validação Kubernetes

Validação em execução concluída em 2026-09-13 no contexto docker-desktop, com CatalogAPI 0.3.0 publicada. Os manifestos foram aplicados, migrations/configurador concluíram e Mongo, CatalogAPI e Kong ficaram Ready. O PVC Mongo está Bound (2 GiB) e o Service permanece ClusterIP.

- Pelo Kong: GET de jogo sem documento retorna 200/notConfigured; PUT administrativo grava e atualiza; GET retorna 200/available com SQL e Mongo.
- Dois PUTs mantêm um único documento UUID BSON, preservam createdAt e limpam campos omitidos/null sem alterar título ou preço SQL.
- Sem token, token inválido ou expirado: 401. Usuário comum: GET 200, PUT 403.
- Requisitos negativos, URL inválida, campos desconhecidos e atributos aninhados: 400. Corpo acima de 64 KiB: 413. Jogo inexistente/inativo: GET/PUT 404.
- Reinício do Mongo preservou o documento no PVC.
- Com Mongo escalado a zero: GET 200/unavailable em aproximadamente 2034 ms e PUT 503, com warnings nos logs da API.
- Após restaurar uma réplica, Mongo voltou a Ready e os detalhes originais continuaram disponíveis.
- Somente o jogo temporário e seu documento foram removidos, verificando ID/título e ausência de referências. Port-forward de teste encerrado. Nenhum script/Job auxiliar foi adicionado e nenhum fluxo de compra/pagamento foi executado.
