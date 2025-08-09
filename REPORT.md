## REPORT

### Čo som postavil
- End‑to‑end pipeline: Kafka → C++ anonymizér → ClickHouse cez Nginx proxy (rate‑limit 1 req/min)
- Anonymizácia IP: posledný oktet nahrádzam „X“ (napr. 1.2.3.4 → 1.2.3.X)
- Semantika doručovania: at‑least‑once (offsety commitujem až po úspešnom vložení do CH)
- Flush režim: najviac 1× za minútu; batch sa medzičasom akumuluje (a pri „tichu“ sa flushne aj bez nových správ)
- Schéma: `logs.http_log` + materializovaný pohľad do `logs.http_log_agg` (SummingMergeTree) pre rýchle prehľady

### SQL v skratke
- `logs.http_log` → MergeTree, partition by day, order by `(timestamp, resource_id, response_status, cache_status, remote_addr)`
- `logs.http_log_agg` + MV `logs.http_log_mv` → `sum(bytes_sent)`, `count()` pre rýchle dashboardy

### Odpovede na otázky zo zadania
- **Latencia dát**: kvôli 1 req/min posielam dávku približne raz za ~60–70 s (flush okno + sieť + CH). Ak by sme mohli, znížime to navýšením limitu alebo shardingom.
- **Strata dát**: nie – offsety commitujem až po úspechu. Pri páde pred INSERTom sa správy po reštarte prehrajú znova (at‑least‑once).
- **Duplicity**: môžu vzniknúť, ak proces spadne po INSERTe a pred commitom. V praxi sa dajú minimalizovať buď ReplacingMergeTree s unikátnym kľúčom (topic/partition/offset), alebo `deduplicate_blocks=1`, prípadne agregovať nad MV (počty/sumy sú robustné).
- **Agregované dotazy**: dashboardy idú nad `logs.http_log_agg`, čítanie je rýchle (sekundy), poradie podľa `(resource_id, response_status, cache_status, remote_addr)`.
- **Disk (príklad)**: 1 000 msg/s × ~150 B po kompresii ≈ 12.96 GB/deň; 30 dní ≈ ~0.39 TB raw. Agregovaná tabuľka je rádovo menšia.

### Limity a kam ďalej
- Rate‑limit 1 req/min je úzke hrdlo (latencia ~1 min). Riešenia: vyšší limit, sharding proxyn/CH, alebo bufferovanie do medzivrstvy a INSERT SELECT.
- Deduplikácia: v produkcii by som pridal ReplacingMergeTree s kľúčom `(topic, partition, offset)` alebo `dedup_token` a `deduplicate_blocks=1`.
- Backpressure: pri plnom batche čakám do najbližšieho okna (pamäť nerastie). Pre extrémne toky sa dá doplniť lokálny on‑disk buffer.
- Observabilita: export batch size, flush duration, retry count, Kafka lag, commit latency (Prometheus). Teraz je zapojený JMX→Prometheus→Grafana.

### Poznámky k spúšťaniu
- `docker compose up -d` spustí Kafka/CH/proxy/producer/Prometheus/Grafana/JMX, anonymizér spúšťam `docker compose run --rm anonymizer` (alebo `up -d anonymizer`).
- Grafana (admin/kafka) → Kafka broker dashboardy (latencie, idle %, RPS). ClickHouse ingest si overím cez `SELECT count(), max(timestamp) FROM logs.http_log`.

### Poznámka k produkčnej pripravenosti
- Pred nasadením do produkcie by som doplnil širšie testy:
  - Záťaž okolo proxy limitu (1 req/min): rôzne rýchlosti produceru, validácia veľkosti batchu, retry a end‑to‑end latencií.
  - Failure injection: výpadky CH/proxy, sieť, reštarty Kafka – overenie at‑least‑once správania a stability.
  - Duplicitné scenáre (pád po inserte, pred commitom): validácia zvolenej dedupe stratégie (ReplacingMergeTree/dedup token) podľa potrieb konzumentov.
  - Backpressure a pamäť pod dlhším špičkovým loadom (so/bez idle úsekov).
  - Observabilita: alerty na nárast flush duration, retry, lag; SLA panel v Grafane.


