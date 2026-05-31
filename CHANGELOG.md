# Changelog

Todas as mudanças notáveis deste projeto são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [0.3.0] — 2026-05-31

Modo distribuído **opt-in** via Horde. Aditivo e **não-breaking**: o default
`distribution: :local` mantém o comportamento single-node 100% idêntico. Toda a
camada de storage e algoritmos fica inalterada — a distribuição é uma casca fina
(3 módulos novos + wiring na API).

### Added

- **`MeliGraph.Distributed`** — supervisor de cluster da lib (o app adiciona 1×
  na árvore). Sobe `MeliGraph.HordeRegistry` (descoberta cluster-wide) e
  `MeliGraph.HordeSupervisor` (`Horde.DynamicSupervisor` + `Horde.UniformDistribution`
  para eleger o nó dono de cada grafo por consistent hashing).
- **`MeliGraph.Router`** — roteamento transparente. Resolve a rota localmente
  (modo `:local` ou este nó é o dono → *fast path*, ETS direto, multi-reader) ou,
  num nó remoto, envia a operação inteira ao dono via **1 `:erpc.call`** (comando +
  resultado cruzam a rede, nunca o acesso ao dado).
- **`MeliGraph.Bootstrapper`** — reconstrói o grafo via a MFA `on_ready` no boot
  e em cada realocação (failover). Não-bloqueante; expõe `ready?/1`.
- **`MeliGraph.Reconciler`** — rede de segurança do failover (1 por nó). O failover
  automático do Horde sofre uma corrida sob queda abrupta do dono (o `NodeListener`
  com `members: :auto` pode remover o nó morto do CRDT antes do processo órfão ser
  realocado → grafo perdido ~50-60% das vezes). O reconciliador checa `lookup_owner`
  a cada `reconcile_interval` e re-dispara `ensure_started/1` quando o grafo fica
  sem dono além do `reconcile_grace`. Guard por `lookup_owner` (registro estável em
  `conf.name`) evita dupla-alocação apesar do `randomize_child_id` do Horde. Novos
  campos de `Config`: `reconcile_interval` (2s) e `reconcile_grace` (5s). Novo
  evento `[:meli_graph, :reconciler, :reassert]`.
- **Config**: campos `distribution` (`:local | :horde`), `on_ready`
  (`nil | {mod, fun, args}`), `cluster_call_timeout` (default 15s),
  `reconcile_interval` (default 2s) e `reconcile_grace` (default 5s), com validação.
- **API pública**: `MeliGraph.ready?/1` e `MeliGraph.owner_node/1`.
- **Erros novos** (modo distribuído): `{:error, :graph_unavailable}` e
  `{:error, :graph_timeout}` em `recommend/4` e afins.
- **Telemetry**: `[:meli_graph, :router, :remote_call, :start|:stop|:exception]`,
  `[:meli_graph, :instance, :started]`, `[:meli_graph, :instance, :ready]`.
- **Deps opcionais** `:horde ~> 0.10` e `:libring ~> 1.7` (só baixadas pelo app
  que ativa o modo distribuído).
- **Testes multi-nó** com `:peer` (tag `:distributed`, excluída por default):
  descoberta cross-node, insert/recommend remoto, failover + rebuild, degradação.
- **Docs**: `docs/distribution.md` (guia operador), este `CHANGELOG.md`.

### Changed

- `MeliGraph.start_link/1` e `child_spec/1` agora são *distribution-aware*: em
  `:horde` com contexto de cluster, alocam via Horde; senão, caminho de hoje.
- `ConfigHolder` registra a instância no `Horde.Registry` (além do Registry
  local) quando em modo distribuído, ligando a entrada ao ciclo de vida do dono.
- Toda a API pública passa pelo `Router` (no modo `:local` o fast path é uma
  chamada direta — zero overhead de Horde/`:erpc`).
- `@version` `0.2.1` → `0.3.0`.

### Notes

- **Sem breaking changes.** Apps single-node existentes não precisam mudar nada
  e não baixam Horde.
- O gate `distributed_context?()` (= `Code.ensure_loaded?(Horde.Registry) and
  Node.alive?()`) faz `distribution: :horde` degradar graciosamente para `:local`
  fora de um cluster.

## [0.2.1] — Pesos nas arestas + Nx obrigatório

- Campo `weight :: float()` em arestas; `insert_edge/5`; `Ã = D^(-1/2)·W·D^(-1/2)`
  ponderada no LightGCN. `:nx` virou dependência obrigatória.

## [0.2.0] — LightGCN

- Embeddings colaborativos via `Nx.Defn` + BPR loss; `train_embeddings/2`,
  `load_embeddings/2`, `embeddings_ready?/1`; fallback transparente para SALSA.

## [0.1.0] — Fundação

- Config + Registry + Supervisor; storage ETS com segmentação temporal;
  PageRank, SALSA, SimilarItems, GlobalRank; plugin system; telemetry.
