# Padrões OTP

Padrões extraídos do Oban (Elixir) e adaptados para o MeliGraph.

## Config Struct Centralizado

**Problema**: `Application.get_env` é global e não suporta múltiplas instâncias.

**Solução**: Um struct `MeliGraph.Config` é criado e validado uma vez no `start_link`, depois passado para todos os processos via opção `conf:`.

```elixir
# Validação no boot — falha rápido se configuração inválida
conf = MeliGraph.Config.new(
  name: :my_graph,
  graph_type: :bipartite,
  segment_max_edges: 1_000_000,
  testing: :sync
)

# Cada processo recebe o conf
GenServer.start_link(Writer, conf, name: via(conf, :writer))
```

### Benefícios

- Validação centralizada no boot (fail-fast)
- Suporte a múltiplas instâncias com configurações diferentes
- Sem acoplamento com `Application` — testável isoladamente
- Struct imutável — sem race conditions na configuração

## Registry para Lookup

**Problema**: Nomes hardcoded (`MeliGraph.Writer`) impossibilitam múltiplas instâncias.

**Solução**: Cada instância cria seu próprio `Registry` com namespace isolado.

```elixir
# Registro
GenServer.start_link(Writer, conf, name: {:via, Registry, {conf.registry, :writer}})

# Lookup
MeliGraph.Registry.via(conf, :writer)    # → {:via, Registry, {registry, :writer}}
MeliGraph.Registry.whereis(conf, :writer) # → pid | nil
```

O `ConfigHolder` registra o `Config` no Registry com o valor como terceiro elemento da tupla `:via`, permitindo que qualquer módulo recupere a configuração da instância sem manter estado.

## Modos de Testing

**Problema**: Testes com processos async são frágeis, não-determinísticos e lentos.

**Solução**: Dois modos de operação controlados pela opção `testing:`:

| Modo | Comportamento |
|------|-------------|
| `:disabled` (produção) | Writer usa `cast` (async), Query usa cache, plugins ativos |
| `:sync` (teste) | Writer usa `call` (sync), Query computa inline, plugins desabilitados |

```elixir
# No teste — tudo síncrono e determinístico
MeliGraph.start_link(name: :test, graph_type: :bipartite, testing: :sync)

MeliGraph.insert_edge(:test, "u1", "p1", :like)  # ← retorna somente após inserção
{:ok, recs} = MeliGraph.recommend(:test, "u1", :content)  # ← computa inline
```

### Como funciona na supervision tree

No modo `:sync`, o supervisor **não inicia**:
- `MeliGraph.Plugins.Supervisor` (Pruner, CacheCleaner)

Estes componentes são desnecessários em testes pois:
- Pruning não é relevante em testes curtos
- Cache não é usado (computação inline)

## Plugin Behaviour

**Problema**: Tarefas periódicas (pruning, cache cleanup) precisam ser configuráveis, testáveis e opcionais.

**Solução**: Cada plugin é um GenServer supervisionado que implementa o behaviour `MeliGraph.Plugin`.

```elixir
defmodule MeliGraph.Plugin do
  @callback start_link(keyword()) :: GenServer.on_start()
  @callback validate(keyword()) :: :ok | {:error, String.t()}
end
```

### Plugins disponíveis

| Plugin | Responsabilidade | Intervalo padrão |
|--------|-----------------|-----------------|
| `Pruner` | Remove segmentos com idade > `segment_ttl` | 5 minutos |
| `CacheCleaner` | Remove entradas expiradas do cache | 1 minuto |

### Configuração

```elixir
MeliGraph.start_link(
  name: :my_graph,
  graph_type: :bipartite,
  plugins: [
    {MeliGraph.Plugins.Pruner, interval: :timer.minutes(10)},
    {MeliGraph.Plugins.CacheCleaner, interval: :timer.seconds(30)}
  ]
)
```

## Graceful Shutdown

O `Ingestion.Writer` usa `trap_exit` para garantir que arestas pendentes na mailbox são processadas antes do shutdown:

```elixir
def init(conf) do
  Process.flag(:trap_exit, true)  # ← intercepta sinais de shutdown
  {:ok, %{conf: conf}}
end

def terminate(_reason, state) do
  drain_mailbox(state.conf)  # ← processa tudo que resta na mailbox
  :ok
end
```

Isso é crítico em cenários onde o sistema recebe um SIGTERM (deploy, scaling) e há arestas em trânsito na mailbox do GenServer.

## Telemetry-First

Todas as operações críticas são instrumentadas via `:telemetry.span/3`:

```elixir
MeliGraph.Telemetry.span([:ingestion, :insert_edge], %{conf: conf}, fn ->
  result = do_insert(conf, source, target, edge_type)
  {result, %{source: source, target: target}}
end)
```

### Eventos emitidos

| Evento | Quando |
|--------|--------|
| `[:meli_graph, :ingestion, :insert_edge, :start\|:stop]` | Inserção de aresta |
| `[:meli_graph, :query, :recommend, :start\|:stop]` | Consulta de recomendação |
| `[:meli_graph, :graph, :create_segment, :start\|:stop]` | Rotação de segmento |
| `[:meli_graph, :plugin, :prune, :start\|:stop]` | Execução do Pruner |
| `[:meli_graph, :plugin, :cache_clean, :start\|:stop]` | Execução do CacheCleaner |

### Exemplo de handler

```elixir
:telemetry.attach("log-inserts", [:meli_graph, :ingestion, :insert_edge, :stop],
  fn _event, %{duration: d}, meta, _config ->
    Logger.info("Edge inserted in #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end, nil)
```

## Supervision Strategy: rest_for_one

A estratégia `rest_for_one` garante que se um processo essencial crashar, todos os processos iniciados **depois** dele também reiniciam:

```
Registry → ConfigHolder → IdMap → SegmentManager → Writer → Store → Plugins
                                       ↑
                                  Se crashar aqui,
                                  Writer, Store e Plugins
                                  reiniciam também
```

Isso evita situações onde o `Writer` continua enviando inserts para tabelas ETS que não existem mais (porque o `SegmentManager` crashou e perdeu suas referências).
