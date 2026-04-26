import Config

# Compilação JIT do `Nx.Defn` via EXLA (XLA/CPU/GPU). Reduz o treino do
# LightGCN de ~minutos por época para milissegundos.
#
# A lib declara `:exla` e `:nx` como `optional: true` no `mix.exs`. Só
# ativamos o backend quando o módulo está disponível — apps que consomem
# a lib só pra usar SALSA/PageRank não pagam o custo do download/compile
# do XLA.
#
# Apps caller (ex: Melivra) devem replicar este bloco no seu próprio
# `config/runtime.exs` ou `config/config.exs` para o trainer rodar rápido
# em produção.
# Mix carrega este arquivo antes das deps entrarem no code path, então
# `Code.ensure_loaded?(EXLA)` aqui retornaria `false` mesmo com EXLA
# instalado. Como `config/config.exs` da lib **só é aplicado quando o
# próprio MeliGraph é o projeto raiz** (testes, bench, dev), é seguro
# setar incondicionalmente — para consumidores da lib, esses configs não
# vazam, eles fazem o seu próprio em `config/runtime.exs`.
config :nx, default_backend: EXLA.Backend
config :nx, :default_defn_options, compiler: EXLA
