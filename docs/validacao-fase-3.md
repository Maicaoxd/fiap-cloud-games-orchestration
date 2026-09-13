# Validação — FIAP Cloud Games, Fase 3

Auditoria realizada em 13/09/2026 com o enunciado `TC NETT - Fase 3.pdf`, as seis suítes automatizadas, Docker Compose e Kubernetes local Docker Desktop.

## Matriz de requisitos

| Requisito | Implementação e evidência | Situação técnica |
| --- | --- | --- |
| Entrada HTTP centralizada e roteamento | Kong OSS 3.9.3, dois Services, prefixos /identity e /catalog; cadastro, login e catálogo exercitados pelo proxy | Atendido |
| JWT no Gateway | Tokens ausente, adulterado e expirado retornaram 401; token válido chegou às APIs; perfil comum recebeu 403 em operação administrativa | Atendido |
| Configuração do Gateway versionada | PowerShell/Admin API, PostgreSQL exclusivo; reexecução preservou IDs e reinicialização preservou configuração | Atendido |
| NotificationsAPI substituída por função | UserCreatedFunction e PaymentProcessedFunction, Azure Functions v4/.NET 10 isolado, RabbitMQ Trigger e envelope MassTransit | Atendido localmente |
| Function com código e infraestrutura em repositório próprio | Dockerfile, docker-compose.dev.yml, rabbitmq/ e k8s/ no repositório notifications-function; inclusão direta pela orquestração | Atendido |
| Logs centralizados da Function | Alloy → Loki → Grafana; boas-vindas e confirmação de compra encontradas no Loki e exibidas no dashboard | Atendido |
| Observabilidade — Opção A | prometheus-net.AspNetCore em UsersAPI e CatalogAPI; dois targets UP; dashboard com latência p95, total, contagem por status e taxa de erros 5xx | Atendido |
| Manifestos Kubernetes de monitoração | Prometheus, Grafana, Loki e Alloy, ConfigMaps, Services, PVCs e RBAC de leitura restrita do Alloy | Atendido |
| NoSQL integrado por driver oficial .NET | Documento MongoDB com _id UUID vinculado ao Game.Id; PUT de detalhes e GET composto SQL/Mongo validados | Atendido |
| Cache Redis integrado | IDistributedCache/StackExchange.Redis, TTL de cinco minutos, HIT/MISS e invalidação por alteração SQL e Mongo | Atendido |
| Código-fonte e instruções centralizadas | Links dos repositórios e guias de execução Docker/Kubernetes no README central; READMEs revisados | Atendido |

O esclarecimento do professor Lucas Lima de 08/09/2026, fornecido pelo aluno, permite demonstrar a Function localmente. O container mantém o host ativo; a execução validada não demonstra autoscaling ou scale-to-zero. Não houve publicação ou criação de recursos Azure, uso de KEDA ou serviços pagos.

## Testes automatizados

| Projeto | Aprovados | Falhas | Ignorados |
| --- | ---: | ---: | ---: |
| UsersAPI | 155 | 0 | 0 |
| CatalogAPI | 115 | 0 | 0 |
| PaymentsAPI | 8 | 0 | 0 |
| Notifications Function | 22 | 0 | 0 |
| NotificationsAPI legada | 5 | 0 | 0 |
| Monólito FiapCloudGames legado | 215 | 0 | 0 |
| **Total** | **520** | **0** | **0** |

As suítes ativas da Fase 3 somam 300 testes. Os outros 220 preservam a cobertura das implementações legadas; não correspondem a workloads adicionais na base padrão.

Os testes foram executados em cada repositório com `dotnet test` e o projeto de testes correspondente, usando os pacotes já restaurados (`--no-restore`). Para reproduzir em checkout novo, execute primeiro `dotnet restore` ou omita essa opção:

```powershell
dotnet test ../fiap-cloud-games-users-api/tests/UsersAPI.Tests/UsersAPI.Tests.csproj
dotnet test ../fiap-cloud-games-catalog-api/tests/CatalogAPI.Tests/CatalogAPI.Tests.csproj
dotnet test ../fiap-cloud-games-payments-api/tests/PaymentsAPI.Tests/PaymentsAPI.Tests.csproj
dotnet test ../fiap-cloud-games-notifications-function/tests/NotificationsFunction.Tests/NotificationsFunction.Tests.csproj
dotnet test ../fiap-cloud-games-notifications-api/tests/NotificationsAPI.Tests/NotificationsAPI.Tests.csproj
dotnet test ../FiapCloudGames/tests/FCG.Tests/FCG.Tests.csproj
```

O monólito emitiu NU1903 para a dependência transitiva Microsoft.OpenApi 2.4.1 ([aviso GHSA-v5pm-xwqc-g5wc](https://github.com/advisories/GHSA-v5pm-xwqc-g5wc)). Esse projeto não integra a stack da Fase 3. Seus testes passaram, mas a dependência deve ser corrigida antes de reutilizar ou publicar a implementação legada. Não foi realizada auditoria de segurança completa.

## Fluxo integrado

O mesmo fluxo foi exercitado em Docker e Kubernetes:

1. Cadastro de usuário sintético pelo Kong: 201.
2. Login real na UsersAPI pelo Kong: 200 e token utilizado nas operações do usuário.
3. Criação administrativa de jogo SQL: 201.
4. PUT de detalhes Mongo: 200; consulta direta confirmou o documento UUID.
5. GET individual: 200, detailsStatus=available e conteúdo Mongo composto com os campos SQL.
6. Nova leitura: resposta cacheada, TTL positivo até 300 segundos.
7. Alteração SQL: 204, chave removida e preço atualizado no GET seguinte.
8. Alteração Mongo: 200, chave removida antes da próxima consulta.
9. Compra com JWT do usuário: 202 e orderId.
10. Pagamento aprovado e biblioteca contendo exatamente o jogo comprado.
11. Nova compra do mesmo jogo: 409, sem gerar outro pedido.
12. Uma notificação de boas-vindas e uma confirmação de compra localizadas no Loki pelo usuário/pedido sintético.

Na instalação Docker vazia, a senha foi definida somente no administrador do ambiente isolado, e seu token foi obtido pelo login normal. No Kubernetes, o administrador e sua senha existentes não foram alterados: operações de preparação usaram um JWT administrativo efêmero de teste assinado com o segredo acadêmico local. Tokens e segredos não integram estas evidências.

### Indicadores coletados no Docker

- TTL Redis observado após a primeira leitura: 297 segundos.
- Logs de cache encontrados para o jogo: 7 CACHE ENCONTRADO, 3 CACHE NÃO ENCONTRADO e 4 CACHE INVALIDADO.
- Quatro filas de negócio: um consumidor por fila, zero mensagens Ready e zero Unacked após o fluxo.
- Cookie RabbitMQ criado com UID/GID 999:999 e permissão 400.
- Kong: os IDs de Services, Routes, plugins, Consumer e credencial não mudaram na reexecução; a configuração persistiu após reiniciar o Gateway.

### Grafana e Prometheus

Os oito painéis do dashboard fcg-apis retornaram séries. Após aguardar amostras suficientes, p95 retornou valores finitos para as duas APIs; a taxa de erros 5xx foi zero no fluxo aprovado. Esses valores representam a demonstração local, não um teste de carga ou SLO.

A interface exibiu ambos os targets UP, contadores incrementados, gráficos e a tabela com colunas API, Status HTTP e Requisições. O dashboard fcg-logs exibiu as duas execuções da Function e as mensagens de boas-vindas e compra. A inspeção visual foi concluída no Docker; no Kubernetes, foram verificadas as fontes, os dashboards provisionados e suas consultas pela API do Grafana.

As fontes e os JSONs dos dashboards são compartilhados entre os ambientes, mas os históricos não são. Erros rejeitados no Kong não aparecem nos contadores das APIs. Contadores são cumulativos desde a inicialização do processo; p95 pode retornar NaN antes de existir tráfego e ao sair da janela de cinco minutos.

## Instalação e preservação dos dados

O teste de inicialização vazia usou o Compose versionado, imagens publicadas e um projeto isolado com volumes novos. Um override temporário alterou apenas portas de inspeção e as URLs correspondentes do Manager. Não modificou autenticação, roteamento, contratos, dependências ou armazenamento do ambiente principal. O inicializador SQL criou o administrador; o catálogo vazio foi preparado pelo procedimento documentado no README.

Os cinco inicializadores Docker terminaram com código 0, e as aplicações e dependências permaneceram em execução. Promtool, Alloy validate e Loki verify-config aprovaram as configurações. Docker Compose e as bases Kustomize integrada e independente da Function foram validados.

O Kubernetes recebeu a base revisada mantendo os oito PVCs existentes. Para não executar duas stacks completas simultaneamente na VM de aproximadamente 8 GB, seus componentes foram temporariamente pausados; RabbitMQ permaneceu em execução para preservar filas e mensagens. Ao concluir, os 16 Deployments estavam prontos com uma réplica cada, os quatro Jobs permaneciam completos e os oito PVCs Bound preservavam seus UIDs originais. Os dois targets Prometheus estavam UP, e as duas notificações continuavam consultáveis no Loki após recriar seus pods.

No Kubernetes, foram removidos apenas os usuários, jogos, pedidos, bibliotecas, documentos Mongo e chaves Redis sintéticos criados pela auditoria, com validação de identidade e referências. Seus logs coletados no Loki foram mantidos para consulta. Os dois projetos Docker temporários e seus 24 volumes exclusivos, criados nesta auditoria, foram removidos após os testes. Nenhum volume ou PVC de dados anteriores foi excluído.

Foram revisados 11 READMEs, os links locais e os exemplos de execução. As instruções centrais não exigem reset de banco, down -v ou exclusão de PVCs. Os sete repositórios não versionam AGENTS.md. Nenhum helper de teste, Job fictício ou script Python foi adicionado ao projeto.

## Correções aplicadas na auditoria

- Infraestrutura Kubernetes da Function e do Azurite transferida para o repositório da Function, sem duplicação e sem alterar a identidade dos recursos.
- Contagem cumulativa por status HTTP acrescentada ao dashboard, preservando o gráfico de respostas por segundo.
- Versões UsersAPI 0.2.1 e CatalogAPI 0.4.1 corrigidas nos guias Mongo/Redis.
- Health check RabbitMQ executado como usuário rabbitmq, evitando a criação concorrente de cookie pertencente a root.
- SQL Servers com limite de processo de 2048 MB, teto de container de 3 GB/GiB e estratégia Recreate no Kubernetes.
- Timeouts das sondagens Prometheus/Grafana ajustados e procedimento de catálogo novo documentado.
- Arquitetura e modelo TXT de entrega adicionados, fora dos READMEs operacionais.

As alterações não modificam o código das APIs ou da Function e não exigem publicar novas imagens de aplicação. As tags existentes foram utilizadas no fluxo integrado aprovado.

## Entrega acadêmica

A implementação técnica atende aos requisitos revisados. O pacote de entrega somente estará completo com:

- Vídeo acessível de até 20 minutos demonstrando Gateway/JWT, Function acionada, logs centralizados, métricas, Mongo e Redis.
- Relatório PDF ou TXT preenchido com grupo, integrantes/usuários Discord, links e URL do vídeo.
- Commits disponibilizados nos repositórios remotos e acesso aos links verificado.

O [modelo TXT](entrega-fase-3.modelo.txt) contém os links reais dos remotes e campos a preencher. A [arquitetura](arquitetura.md) fornece o diagrama e as decisões para a apresentação. O vídeo e a identificação do grupo não foram produzidos ou inventados nesta auditoria.
