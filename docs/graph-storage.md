# Graph Storage

## Segmentação Temporal

Inspirado no GraphJet (Twitter, 2016), o grafo é dividido em **segmentos temporais**. Cada segmento armazena um subconjunto de arestas inseridas em um intervalo de tempo.

```
Tempo ──────────────────────────────────────────►

 [Seg 0]     [Seg 1]     [Seg 2]     [Seg 3 ✏️]
 read-only   read-only   read-only    ativo
 (prunable)  (prunable)  (prunable)   (escrita)
```

### Ciclo de vida

1. O sistema inicia com um único segmento ativo (id: 0)
2. Arestas são inseridas no segmento ativo
3. Quando o segmento atinge `segment_max_edges`, ele é "congelado" (read-only) e um novo segmento ativo é criado
4. O plugin `Pruner` remove periodicamente segmentos com idade > `segment_ttl`
5. Leituras consultam **todos** os segmentos (ativo + congelados)

### Vantagens

- Pruning eficiente: remove um segmento inteiro em O(1), sem iterar arestas
- Sem lock entre escrita e leitura: segmentos congelados são imutáveis
- Controle temporal natural: arestas antigas expiram automaticamente

## Armazenamento em ETS

Cada segmento mantém duas tabelas ETS com tipo `:bag`:

| Tabela | Chave | Valor | Uso |
|--------|-------|-------|-----|
| `ltr` (left-to-right) | source | `{source, target, edge_type}` | Vizinhos de saída |
| `rtl` (right-to-left) | target | `{target, source, edge_type}` | Vizinhos de entrada |

### Por que `:bag` em vez de `:set`?

Com `:set`, um vértice teria uma entrada `{source, [lista_de_vizinhos]}`. A cada leitura, toda a lista é copiada do ETS para o heap do processo leitor. Para vértices com milhares de vizinhos, isso causa pressão no GC.

Com `:bag`, cada aresta é uma entrada independente. O `:ets.lookup/2` retorna apenas as entradas do vértice consultado, e o `:ets.match/2` permite filtrar por tipo de aresta diretamente no ETS.

### Configuração das tabelas

```elixir
:ets.new(:ltr, [:bag, :public, read_concurrency: true])
```

- `:public` — permite leitura direta de qualquer processo (multi-reader)
- `read_concurrency: true` — otimiza para cenários com leitura dominante

## ID Mapping

IDs externos (strings, tuplas, qualquer termo Erlang) são mapeados para inteiros sequenciais compactos. O mapeamento é **global** (não por segmento), garantindo que o mesmo ID externo sempre tenha o mesmo ID interno.

### Implementação

```
Forward:  "user:123" → 0
          "post:456" → 1

Reverse:  0 → "user:123"
          1 → "post:456"
```

Duas tabelas ETS nomeadas por instância:
- `:"#{name}.IdMap.forward"` — externo → interno
- `:"#{name}.IdMap.reverse"` — interno → externo

Um `:atomics` counter garante geração thread-safe de IDs sequenciais.

### Trade-offs

| Decisão | Alternativa | Justificativa |
|---------|-------------|---------------|
| ID map global | Por segmento (GraphJet) | Simplifica random walks cross-segment; o mesmo nó tem sempre o mesmo ID interno |
| `:atomics` counter | GenServer counter | Sem overhead de mensagem; operação atômica nativa |
| Tabelas `:public` | Leitura via GenServer | Permite leitura direta sem gargalo no GenServer (single-writer, multi-reader) |

## SegmentManager

GenServer que orquestra os segmentos:

- **Inserção**: delega para o segmento ativo; rotaciona se cheio
- **Leitura**: agrega resultados de todos os segmentos
- **Pruning**: remove segmentos congelados mais antigos que o cutoff

As operações de leitura (`neighbors_out`, `neighbors_in`) passam pelo GenServer para obter a lista de segmentos, mas leem diretamente das tabelas ETS — o GenServer não é gargalo de leitura.
