# Redis — cache do catálogo no Docker

## O que muda

Apenas GET /catalog/games/{gameId} (internamente /api/games/{gameId}) usa cache-aside. A resposta completa de SQL + Mongo é serializada em JSON por meio de IDistributedCache, com o provider Microsoft.Extensions.Caching.StackExchangeRedis 10.0.9. TTL absoluto de cinco minutos, não renovado por leituras.

A chave efetiva no Redis é `fcg:catalog:games:v1:{gameId}`: o prefixo pertence ao provider, e a versão permite evoluir o contrato. O provider .NET armazena um hash com o JSON no campo data. A resposta contém apenas informações compartilhadas do jogo, nunca JWT, identidade ou biblioteca de usuários. Kong e a API continuam validando JWT antes de executar o caso de uso.

- CACHE HIT: devolve a resposta válida do Redis sem consultar SQL ou Mongo.
- CACHE MISS: busca o jogo SQL ativo, compõe os detalhes Mongo e grava por cinco minutos.
- CACHE INVALIDATED: remove a chave após atualização SQL, desativação ou PUT dos detalhes Mongo.

A listagem, criação de jogo, compras, pedidos e biblioteca não usam Redis. Compras continuam calculando preço e disponibilidade diretamente no SQL, não pela resposta cacheada.

## Ausência, falhas e consistência

Jogo inexistente/inativo (404) não é cacheado. Um jogo sem documento Mongo pode ser cacheado com notConfigured; criar seus detalhes invalida a chave. Uma leitura que resultou em unavailable não entra no cache.

Um cache saudável já existente pode continuar retornando available/notConfigured durante uma queda do Mongo: detailsStatus descreve a resposta armazenada, não um health check atual. Sem cache, permanece a consulta degradada da etapa Mongo.

Falhas operacionais/timeout do Redis são warnings sem credenciais. Cada operação tem limite de um segundo; após uma falha, o adapter scoped evita novas tentativas na mesma requisição. A API segue usando os bancos. Erros inesperados e cancelamento do cliente não são escondidos. Payloads corruptos/incompatíveis no cache são descartados e recarregados.

As alterações invalidam depois de salvar, usando um prazo próprio, mesmo se o cliente desconectar após o commit. Cache e bancos não participam de uma transação. Se uma invalidação falhar durante uma partição de rede, uma chave antiga ainda existente pode reaparecer na reconexão até expirar. Também existe a corrida clássica entre uma leitura/população concorrente e a invalidação. Nesta fase a consistência é eventual, limitada pelo TTL; não foram introduzidos locks distribuídos, outbox ou controle de versões entre bancos. Alterações diretas via SQL/Compass não executam invalidação: espere o TTL ou remova somente a chave daquele jogo.

Redis não é fonte de dados: pode perder ou expulsar todo o cache sem perda de jogos/detalhes. Usa maxmemory 128mb, política allkeys-lru, sem RDB/AOF e sem volume persistente.

## Subir

Na raiz da orquestração:

```powershell
docker compose config --quiet
docker compose build catalog-api
docker compose up -d catalog-redis catalog-api
docker compose ps catalog-redis catalog-api
docker compose logs --tail=100 catalog-redis catalog-api
```

Imagem fixa redis:8.2.9-alpine. Redis 8 oferece a opção open source AGPLv3, conforme as [licenças oficiais](https://redis.io/legal/licenses/). Porta local 127.0.0.1:6379 e autenticação. A senha acadêmica padrão é fcg-local-redis, substituível pela variável FCG_REDIS_PASSWORD; a API e o Redis recebem o mesmo valor pelo Compose.

Configuração da CatalogAPI:

| Variável | Valor no Compose |
| --- | --- |
| Redis__Enabled | true |
| Redis__Configuration | catalog-redis:6379 |
| Redis__Password | FCG_REDIS_PASSWORD ou senha acadêmica padrão |

appsettings.json deixa o cache desabilitado fora do Compose; para execução local configure essas variáveis usando localhost:6379. Mongo e SQL continuam com suas configurações próprias. O Redis não é incluído na readiness da API e não precisa estar acessível para --migrate.

## Inspecionar e experimentar

Abra o redis-cli autenticado sem incluir senha literal no comando:

```powershell
docker compose exec catalog-redis sh -c 'REDISCLI_AUTH="$FCG_REDIS_PASSWORD" redis-cli'
```

Dentro dele, substitua GUID pelo ID do jogo:

```text
PING
EXISTS fcg:catalog:games:v1:GUID
TTL fcg:catalog:games:v1:GUID
HGET fcg:catalog:games:v1:GUID data
```

Para Redis Insight, conecte 127.0.0.1:6379, usuário default e senha configurada. Não exponha essa porta à rede de produção.

1. Faça GET pelo Kong com JWT. Verifique CACHE MISS e TTL entre 1 e 300.
2. Repita o GET. Verifique CACHE HIT; TTL continua caindo.
3. Faça PUT do jogo ou de /details. Antes do próximo GET, EXISTS deve retornar 0.
4. Consulte novamente. Novo MISS e resposta atualizada.
5. Desative o jogo. A chave é invalidada e o GET retorna 404.
6. Para exercitar fallback em ambiente acadêmico, pare apenas catalog-redis; GET continua consultando SQL/Mongo. Religue-o ao terminar.

Não use FLUSHALL/FLUSHDB em bancos compartilhados. Para reiniciar somente o teste, DEL na chave exata de seu jogo é suficiente.

## Arquivos e testes

A interface IGameCache fica em Application/Abstractions/Caching; RedisGameCache e suas opções ficam em Infrastructure/Caching. GetGameUseCase aplica cache-aside; UpdateGameUseCase, DeactivateGameUseCase e UpsertGameDetailsUseCase invalidam depois de persistir. Controllers e contratos HTTP não mudaram.

No repositório CatalogAPI:

```powershell
dotnet test tests/CatalogAPI.Tests/CatalogAPI.Tests.csproj
```

Os testes cobrem TTL/JSON, HIT sem bancos, MISS, cache degradado/corrompido, Redis desabilitado, timeout/falhas/cancelamento e ordem de invalidação após commit.

Kubernetes permanece em CatalogAPI 0.3.0, com Mongo e sem Redis. Esta entrega é Docker; a futura imagem da CatalogAPI com Redis deve receber uma nova tag (sugestão 0.4.0), com configuração/infraestrutura Redis no cluster antes da validação daquela etapa. Nenhuma imagem é publicada automaticamente.

Referência do provider: [cache distribuído no ASP.NET Core](https://learn.microsoft.com/en-us/aspnet/core/performance/caching/distributed?view=aspnetcore-10.0).

## Validação realizada no Docker

- 283 testes aprovados: Users 155, Catalog 115 (94 anteriores + 21 novos), Payments 8, Notifications 5.
- Imagem local da CatalogAPI compilada e Redis autenticado/healthy em 127.0.0.1:6379.
- Pelo Kong: MISS/HIT com mesma resposta, TTL inicial 300 segundos sem renovação no HIT e JWT ausente rejeitado com 401.
- Alterações SQL e Mongo removeram a chave; GET seguinte refletiu os dados atuais. Expiração da chave temporária foi exercitada e repopulada.
- Desativação removeu o cache; GET 404 não criou uma nova chave.
- Mongo fora do ar: HIT continuou disponível; em MISS a resposta unavailable não foi cacheada.
- Redis fora do ar: GET SQL/Mongo e PUT de detalhes continuaram retornando 200; warnings registrados. Após recuperação, cache recebeu os dados atualizados.
- CACHE MISS, CACHE HIT e CACHE INVALIDATED confirmados nos logs.
- Apenas o jogo/documento temporários foram removidos; não restou chave daquele jogo. Bancos e dados existentes preservados. Kubernetes não foi alterado e nenhuma imagem foi publicada.
