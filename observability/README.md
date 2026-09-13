# Observabilidade local - Docker

UsersAPI e CatalogAPI usam `prometheus-net.AspNetCore` 8.2.1. O middleware mede as requisicoes em `/api`, incluindo status retornados pela autenticacao e pelo tratamento de excecoes. Health checks e scrapes nao entram nos contadores HTTP de negocio.

Cada API expoe `/metrics` sem JWT, somente pela rede interna do Compose. As portas diretas das APIs continuam fechadas, e o Kong nao recebe uma rota publica de metrics.

Prometheus busca `/metrics` nas duas APIs a cada 15 segundos, pela porta interna 8080. Ele armazena as series em volume persistente, com retencao de sete dias. As APIs nao enviam metricas ao Prometheus: e o Prometheus que as consulta.

Grafana carrega a fonte `prometheus` e o dashboard `FIAP Cloud Games - APIs` por arquivos versionados de provisioning. O dashboard fica na pasta `FIAP Cloud Games`, com UID `fcg-apis`, filtro por API e atualizacao a cada 15 segundos.

## Subir

Na raiz da orquestracao:

```powershell
docker compose up -d --build users-api catalog-api prometheus
docker compose up -d grafana
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

O ambiente coleta métricas HTTP e de processo de UsersAPI e CatalogAPI. Não inclui alertas, logs centralizados, tracing ou monitoração do Kong. Preserve os volumes ao parar o ambiente.

## Kubernetes

Os manifestos em `k8s/observability` definem Deployments, Services ClusterIP, PVCs e Secret local do Grafana. O Prometheus possui PVC de 2Gi e retencao de sete dias; o Grafana possui PVC de 1Gi. Os processos usam usuarios nao-root, probes de startup/readiness/liveness e limites de memoria.

O Kustomize gera os ConfigMaps diretamente dos arquivos deste diretorio, incluindo a fonte e o mesmo JSON do dashboard usado no Docker. O hash dos ConfigMaps altera o template dos Deployments quando os arquivos mudam, provocando rollout. Nao ha copias de dashboard para sincronizar.

`prometheus/kubernetes.yml` usa Services `users-api:80` e `catalog-api:80`, em vez da porta 8080 dos containers Docker. Esta configuracao inicial pressupoe uma replica por API. Para escalar horizontalmente, substituir targets de Service por descoberta de endpoints/pods; coletar um Service balanceado nao identifica metricas por replica.

### Imagens instrumentadas

A base da orquestração referencia UsersAPI 0.2.0 e CatalogAPI 0.4.0. Disponibilize essas imagens no registry ou runtime dos nós antes de aplicar. Alterar uma tag no manifesto não constrói nem publica a imagem.

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

Consulte erros com `kubectl logs deployment/prometheus -n fiap-cloud-games` e `kubectl logs deployment/grafana -n fiap-cloud-games`. A senha no Secret e somente academica; substituir antes de um ambiente publicado. Services internos nao substituem politicas de rede e controle de acesso ao cluster.
