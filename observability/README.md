# Observabilidade — Docker e Kubernetes

Este ambiente implementa a Opção A de observabilidade: Prometheus e Grafana para métricas de UsersAPI e CatalogAPI. Loki e Alloy acrescentam a coleta centralizada de logs das quatro aplicações, inclusive a Function.

UsersAPI e CatalogAPI usam `prometheus-net.AspNetCore` 8.2.1. O middleware mede as requisicoes em `/api`, incluindo status retornados pela autenticacao e pelo tratamento de excecoes. Health checks e scrapes nao entram nos contadores HTTP de negocio.

Cada API expoe `/metrics` sem JWT, somente pela rede interna do Compose. As portas diretas das APIs continuam fechadas, e o Kong nao recebe uma rota publica de metrics.

Prometheus busca `/metrics` nas duas APIs a cada 15 segundos, pela porta interna 8080. Ele armazena as series em volume persistente, com retencao de sete dias. As APIs nao enviam metricas ao Prometheus: e o Prometheus que as consulta.

Grafana carrega a fonte `prometheus` e o dashboard `FIAP Cloud Games - APIs` por arquivos versionados de provisioning. O dashboard fica na pasta `FIAP Cloud Games`, com UID `fcg-apis`, filtro por API e atualizacao a cada 15 segundos.

## Subir

Na raiz da orquestracao:

```powershell
docker compose up -d --build users-api catalog-api prometheus
docker compose up -d grafana
docker compose up -d loki docker-logs-proxy alloy
```

Prometheus: `http://localhost:9090`. Grafana: `http://localhost:3000`. Ambas as portas sao publicadas somente em 127.0.0.1.

Login local inicial do Grafana: `admin` / `fcg-local-grafana`. Antes da primeira inicializacao, pode-se definir `FCG_GRAFANA_PASSWORD` para substituir essa senha. Depois que o volume estiver inicializado, alterar essa variavel nao troca a senha salva; use a interface do Grafana. Credencial academica, nao usar em producao. Cadastro e acesso anonimo estao desativados.

## Conferir a coleta

Em Prometheus, abra Status > Target health (ou `/targets`). Os jobs `users-api` e `catalog-api` devem estar UP. A consulta `up` deve retornar valor 1 para ambos.

Gere requisicoes que cheguem as APIs pelo Kong. Requisicoes rejeitadas no proprio Kong nao entram nas metricas das APIs. Um POST de login com corpo vazio pode comprovar o encaminhamento sem alterar dados; nao use tentativas de cadastro ou recuperacao de senha para gerar trafego de teste.

Metricas HTTP iniciais:

- `http_requests_received_total`: contador de respostas, com labels como metodo, controller, action e code.
- `http_request_duration_seconds`: histograma da duracao.
- `http_requests_in_progress`: requisicoes em andamento.

O Prometheus acrescenta os labels `job` e `instance` para distinguir as APIs. Tokens, emails e IDs de usuarios nao sao usados como labels. Os endpoints usam templates de rota, evitando criar uma serie por ID.

## Reproduzir pela interface do Grafana

Adicionar uma fonte do tipo Prometheus com URL **`http://prometheus:9090`**, nao localhost: o Grafana consulta o coletor de dentro do container. Confirmar com Save & test.

Abra Dashboards > New > New dashboard > Add visualization. Selecione a fonte Prometheus, troque o editor para Code e configure os paineis abaixo. Nas consultas desta secao, as duas APIs sao selecionadas explicitamente; no JSON versionado, esse filtro usa a variavel `service`.

### Disponibilidade da coleta

Visualizacao Stat, consulta Instant, legenda `{{job}}`. Configure Value mappings: 1 = UP (verde), 0 = DOWN (vermelho).

```promql
up{job=~"users-api|catalog-api"}
```

### Total de requisicoes

Visualizacao Stat, Instant, legenda `{{job}}`. Contador cumulativo desde a inicializacao; reiniciar a API pode zera-lo.

```promql
sum by (job) (http_requests_received_total{job=~"users-api|catalog-api"})
```

### Requisicoes por segundo

Visualizacao Time series, consulta Range, unidade requests/sec, legenda `{{job}}`.

```promql
sum by (job) (rate(http_requests_received_total{job=~"users-api|catalog-api"}[5m]))
```

### Respostas por status HTTP

Time series, Range, unidade requests/sec, legenda `{{job}} HTTP {{code}}`.

```promql
sum by (job, code) (rate(http_requests_received_total{job=~"users-api|catalog-api"}[5m]))
```

### Contagem por status HTTP

Visualização Table, consulta Instant com Format = Table. O contador representa as respostas desde a inicialização de cada processo, não apenas o intervalo selecionado. Oculte Time e renomeie job para API, code para Status HTTP e Value para Requisições usando a transformação Organize fields.

```promql
sum by (job, code) (http_requests_received_total{job=~"users-api|catalog-api"})
```

### Erros 5xx (%)

Time series, Range, unidade Percent (0-100). A consulta abaixo e a forma basica; o JSON inclui fallback por job para mostrar zero quando nao ha series 5xx, e `clamp_min` para evitar divisao por zero.

```promql
100 * sum by (job) (rate(http_requests_received_total{job=~"users-api|catalog-api",code=~"5.."}[5m]))
 / sum by (job) (rate(http_requests_received_total{job=~"users-api|catalog-api"}[5m]))
```

### Latencia p95

Time series, Range, unidade seconds, legenda `{{job}}`.

```promql
histogram_quantile(0.95,
  sum by (job, le) (rate(http_request_duration_seconds_bucket{job=~"users-api|catalog-api"}[5m]))
)
```

O p95 e estimado pelos buckets do histograma, nao e uma media. Sem requisicoes na janela, pode mostrar No data/NaN. Nao e substituido por zero.

### Memoria do processo

Time series, Range, unidade bytes, legenda `{{job}}`.

```promql
process_working_set_bytes{job=~"users-api|catalog-api"}
```

Salve o dashboard. Para reproduzir o filtro, abra Settings > Variables e adicione `service`, tipo Custom, valores `users-api,catalog-api`, Multi-value e Include All habilitados, Custom all value `users-api|catalog-api`. Nas consultas substitua o filtro fixo por `job=~"${service:regex}"`. O JSON existente ja tem essa configuracao.

## Reproduzir pelo repositorio

- `prometheus/docker.yml`: scrape a cada 15s, timeout 10s, dois jobs com targets na rede Docker.
- `grafana/provisioning/datasources/prometheus.yml`: fonte, URL interna, UID e intervalo 15s.
- `grafana/provisioning/dashboards/fcg.yml`: provider que le os arquivos da pasta de dashboards.
- `grafana/dashboards/fcg-apis.json`: layout, consultas, unidades, legendas e variavel.
- `docker-compose.yml`: monta esses arquivos somente para leitura e persiste as series e o banco do Grafana em volumes.

Em outra maquina, tenha os repositorios lado a lado e execute os comandos da secao Subir. O provisioning cria a fonte/dashboard no primeiro startup e reconcilia a configuracao em execucoes futuras, sem precisar cadastrar tudo manualmente.

Para mudar targets/intervalos, edite `prometheus/docker.yml`, valide com `docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml` e execute `docker compose restart prometheus`. Para mudar a fonte, edite o YAML e execute `docker compose restart grafana`. Mudancas no JSON do dashboard sao verificadas a cada 30s.

Edicoes pela interface continuam permitidas, mas nao alteram os arquivos montados. Para preserva-las no projeto, exporte o JSON do dashboard, substitua `grafana/dashboards/fcg-apis.json` e versione a alteracao. A configuracao em arquivo e a fonte de reproducao: uma atualizacao do arquivo pode sobrescrever a versao editada na interface.

## Validacao

Abra `http://localhost:9090/targets`: ambos os targets devem estar UP. No Grafana, Connections > Data sources > prometheus > Save & test deve confirmar a conexao. O dashboard esta em `http://localhost:3000/d/fcg-apis`.

Os graficos mostram somente series existentes. Gere trafego que alcance as APIs; `rate` requer ao menos duas amostras do contador. Nao e necessario simular erro 5xx em producao nem alterar dados para verificar o dashboard. Disponibilidade UP significa coleta funcionando, nao que todas as dependencias do dominio estejam saudaveis.

O ambiente coleta métricas HTTP e de processo de UsersAPI e CatalogAPI e centraliza logs das aplicações com Loki e Alloy no Docker e Kubernetes. Não inclui alertas, tracing ou monitoração do Kong. Preserve os volumes ao parar o ambiente.

## Logs centralizados no Docker

Loki 3.7.7 armazena os logs em uma instância local, usando TSDB, schema v13 e volume loki-data. O Compactor aplica a retenção de 72 horas; a exclusão física acontece posteriormente, conforme o ciclo de compactação e o atraso de duas horas. A retenção não é um limite de espaço em disco.

Alloy 1.19.2 descobre os containers deste projeto Compose e lê os logs de notifications-function, users-api, catalog-api e payments-api. Bancos, migradores, Kong, implementação legada e outros projetos não são coletados. Os rótulos service, compose_project e container identificam a origem; usuários, e-mails e pedidos permanecem no conteúdo, não viram rótulos. Os pontos de leitura são persistidos em alloy-data.

docker-logs-proxy usa tecnativa/docker-socket-proxy v0.5.0 e fornece somente GET/HEAD nas seções containers, networks, events, ping e version da API Docker. A leitura de networks é necessária para descobrir os containers. Escritas e outras seções ficam bloqueadas. Apenas Alloy compartilha sua rede interna; o coletor não monta diretamente o socket. A permissão containers ainda expõe metadados, incluindo variáveis de ambiente, por isso mantenha o proxy sem portas publicadas e não adicione outros serviços à rede docker-logs-network. Montar o socket somente para leitura não seria suficiente para bloquear operações de escrita na API.

Loki e Alloy também não publicam portas no host. A fonte loki é provisionada no Grafana com UID fcg-loki e URL interna http://loki:3100. A autenticação do Loki está desativada apenas para esse ambiente local isolado; uma instalação publicada exige controle de acesso. Os logs podem conter dados pessoais: use dados sintéticos nas demonstrações e não registre senhas ou tokens.

### Visualizar e pesquisar

Abra http://localhost:3000/d/fcg-logs. O dashboard FIAP Cloud Games - Logs fica na mesma pasta do dashboard de métricas e permite selecionar a aplicação. A seleção inicial é notifications-function; ajuste o intervalo de tempo para incluir a execução desejada.

Em Explore, selecione a fonte loki, use o editor Code e execute:

```logql
{service="notifications-function"}
```

Para filtrar as boas-vindas:

```logql
{service="notifications-function"} |= "E-mail de boas-vindas enviado"
```

Para consultar uma compra, substitua ORDER_ID pelo identificador retornado no HTTP 202:

```logql
{service="notifications-function"} |= "ORDER_ID"
```

Faça cadastro, login e compra pelo Kong e confira a notificação e a biblioteca atualizada. Os e-mails são simulados. Mensagens rejeitadas antes de chegar à Function não geram uma notificação.

### Configurar e solucionar problemas

- loki/docker.yml: armazenamento, WAL e retenção; reinicie loki após editar.
- alloy/docker.alloy: descoberta, filtro de aplicações, rótulos e envio; reinicie alloy após editar.
- grafana/provisioning/datasources/loki.yml: fonte Loki; reinicie grafana após editar.
- grafana/dashboards/fcg-logs.json: visualização; o provider existente verifica mudanças a cada 30 segundos.

Para reproduzir pela interface, adicione uma fonte Loki com URL http://loki:3100 e confirme com Save & test. Crie um painel do tipo Logs, selecione essa fonte e use a consulta {service="notifications-function"}.

```powershell
docker compose config --quiet
docker compose up -d loki docker-logs-proxy alloy grafana
docker compose ps
docker compose logs --tail=100 loki alloy docker-logs-proxy
```

Sem logs: confira se a aplicação está em execução, o intervalo selecionado e os logs de Alloy. A variável FCG_COMPOSE_PROJECT é preenchida com COMPOSE_PROJECT_NAME pelo Compose, inclusive para projetos com nome personalizado. Somente containers em execução são descobertos; mantenha o coletor ativo durante os testes. Logs já enviados permanecem no Loki após recriar um container de aplicação, até a retenção removê-los.

Se o Loki rejeitar entradas antigas, gere um evento novo; a configuração rejeita logs anteriores a 72 horas. Não use docker compose down -v para solucionar problemas: isso apaga os volumes. Loki e Alloy desta seção são exclusivos do Compose, sem conexão com serviços de nuvem.

## Kubernetes

Os manifestos em `k8s/observability` definem Deployments, Services ClusterIP, PVCs e Secret local do Grafana. O Prometheus possui PVC de 2Gi e retencao de sete dias; o Grafana possui PVC de 1Gi. Os processos usam usuarios nao-root, probes de startup/readiness/liveness e limites de memoria.

As sondagens HTTP do Prometheus e Grafana têm timeout de cinco segundos; a liveness exige seis falhas consecutivas antes de reiniciar o container. Essas sondagens operacionais não dispensam a verificação dos targets e das fontes de dados.

Loki possui PVC de 1 GiB, Service interno na porta 3100, WAL e a mesma configuração de retenção de 72 horas definida em loki/docker.yml. Alloy usa alloy/kubernetes.alloy, uma única réplica e descoberta pela API Kubernetes, sem socket Docker, acesso aos arquivos dos nós ou DaemonSet. Ambos possuem probes, limites de recursos e executam sem root. A raiz dos containers Loki e Alloy é somente para leitura; diretórios temporários usam emptyDir.

A ServiceAccount alloy possui Role e RoleBinding somente em fiap-cloud-games: get/list/watch de pods e get de pods/log. Não recebe acesso a Secrets, escrita em recursos ou leitura de pods em outros namespaces. A descoberta seleciona os rótulos app das quatro aplicações e exclui initContainers. Os logs recebem os rótulos service, namespace, pod e container, sem IDs de usuário ou pedido como rótulos.

O Kustomize gera os ConfigMaps diretamente dos arquivos deste diretorio, incluindo a fonte e o mesmo JSON do dashboard usado no Docker. O hash dos ConfigMaps altera o template dos Deployments quando os arquivos mudam, provocando rollout. Nao ha copias de dashboard para sincronizar.

As fontes prometheus e loki e os dashboards fcg-apis e fcg-logs são compartilhados entre Docker e Kubernetes; o banco do Grafana e o histórico dos coletores são independentes em cada ambiente. A fonte Loki continua usando http://loki:3100 internamente.

`prometheus/kubernetes.yml` usa Services `users-api:80` e `catalog-api:80`, em vez da porta 8080 dos containers Docker. Esta configuracao inicial pressupoe uma replica por API. Para escalar horizontalmente, substituir targets de Service por descoberta de endpoints/pods; coletar um Service balanceado nao identifica metricas por replica.

### Imagens instrumentadas

A base da orquestração referencia UsersAPI 0.2.1 e CatalogAPI 0.4.1. Disponibilize essas imagens no registry ou runtime dos nós antes de aplicar. Alterar uma tag no manifesto não constrói nem publica a imagem.

### Aplicar e validar

Confirme que `kubectl config current-context` aponta para o cluster desejado e que `kubectl get nodes` responde. Disponibilize as imagens referenciadas pelos manifestos.

Ao atualizar a imagem de um Job existente, confirme sua conclusão e recrie somente esse Job para evitar erro de template imutável. Em um cluster novo, aplique diretamente a base:

```powershell
kubectl apply -k ./k8s
kubectl wait --for=condition=complete job/users-api-migration job/catalog-api-migration -n fiap-cloud-games --timeout=600s
kubectl rollout status deployment/users-api -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/catalog-api -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/prometheus -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/grafana -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/loki -n fiap-cloud-games --timeout=300s
kubectl rollout status deployment/alloy -n fiap-cloud-games --timeout=300s
kubectl get pvc,services -n fiap-cloud-games
```

Em dois terminais, mantenha os encaminhamentos abertos. As portas locais diferentes evitam conflito com o Compose:

```powershell
kubectl port-forward svc/prometheus 9091:9090 --address 127.0.0.1 -n fiap-cloud-games
```

```powershell
kubectl port-forward svc/grafana 3001:3000 --address 127.0.0.1 -n fiap-cloud-games
```

Abra `http://localhost:9091/targets` e confirme ambos os jobs UP. Grafana em `http://localhost:3001/d/fcg-apis`, login local inicial `admin` / `fcg-local-grafana`. A fonte usa `http://prometheus:9090` internamente, nao a porta encaminhada 9091. PVCs novos nao recebem automaticamente o historico dos volumes do Compose.

Para os logs, abra http://localhost:3001/d/fcg-logs ou use a fonte loki no Explore com as mesmas consultas LogQL da seção Docker. Cadastre um usuário e faça uma compra pelo Kong encaminhado; confirme as notificações e a biblioteca. Logs enviados continuam consultáveis após a recriação dos pods, até a retenção removê-los. Mantenha Alloy ativo durante o fluxo; logs indisponíveis na API não podem ser recuperados pelo coletor. Seu diretório de trabalho é temporário; a persistência dos logs coletados pertence ao PVC do Loki.

```powershell
kubectl logs deployment/alloy -n fiap-cloud-games --tail=100
kubectl logs deployment/loki -n fiap-cloud-games --tail=100
```

Se houver Forbidden nos logs do Alloy, confira ServiceAccount, Role e RoleBinding. Sem resultados no Grafana, confira a conexão da fonte loki, o intervalo de tempo, a coleta e se a aplicação está executando no namespace correto. Nenhum componente requer Grafana Cloud ou publicação na Azure. O Loki não habilita autenticação neste exemplo; ClusterIP não substitui controles de rede e acesso para ambientes publicados.

Consulte erros com `kubectl logs deployment/prometheus -n fiap-cloud-games` e `kubectl logs deployment/grafana -n fiap-cloud-games`. A senha no Secret e somente academica; substituir antes de um ambiente publicado. Services internos nao substituem politicas de rede e controle de acesso ao cluster.
