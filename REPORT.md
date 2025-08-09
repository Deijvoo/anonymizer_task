## REPORT

### Prehľad riešenia
- Kafka -> C++ anonymizér -> ClickHouse cez Nginx proxy (1 req/min). 
- Anonymizácia: posledný oktet IP na "X".
- At-least-once: manual commit offsetov až po úspešnom INSERTe.
- Flush: max 1x za 60 s (rešpektovanie rate-limitu na klientovi); batch sa medzitým akumuluje.
- Schéma: `logs.http_log` + materializovaný pohľad do `logs.http_log_agg` (SummingMergeTree) pre rýchle agregácie.

### DDL (stručne)
- `logs.http_log` (MergeTree, partition by day, order by `(timestamp, resource_id, response_status, cache_status, remote_addr)`).
- `logs.http_log_agg` (SummingMergeTree) + MV `logs.http_log_mv` (sum bytes, count requests).

### Otázky a odpovede (zadanie)
- Latencia dát:
  - Aplikácia flushuje 1× za minútu (kvôli 1 req/min). Priemerná end-to-end latencia ~ 30–70 s (čakanie na flush okno + sieť/ClickHouse). 
  - Dá sa znížiť zvýšením limitu na proxy a zmenou flush intervalu, alebo paralelnými shardami (viď návrhy nižšie).

- Kedy môžeme stratiť dáta?
  - S vypnutým auto-commitom a commitom po úspešnom INSERTe: strata prakticky nehrozí. Pri páde pred INSERTom/commitom dôjde k re-playu tých istých správ po reštarte.
  - Riziko je iba pri poškodení lokálnej RAM (batch v pamäti) pri páde procesu PRED INSERTom – v tom prípade sa správy z Kafka prehrajú znova (bez straty), lebo nebol commit.

- Duplicity v uložení?
  - Áno, ak proces spadne PO úspešnom INSERTe a PRED commitom offsetov. Po reštarte sa správy znova prečítajú → INSERT druhýkrát.
  - Zmiernenie:
    - Aplikovať deduplikáciu v CH: napr. `ReplacingMergeTree` s `version` alebo `uniq_state/uniqExact` pri agregácii; alebo `INSERT ... SETTINGS deduplicate_blocks=1` (zníži duplicitné bloky).
    - Pridať unikátny kľúč per záznam (napr. `(resource_id, timestamp, url, method, remote_addr)` + hash) a použiť `ReplacingMergeTree`.
    - Alebo akceptovať duplicitné raw riadky a spoliehať sa na agregovanú tabuľku (SummingMergeTree) do ktorej pôjde `sum`/`count` – duplicitné RAW riadky sa agregujú; pri presných metrikách však môže dôjsť k nafúknutiu.

- Char. času dotazov pre agregácie:
  - Dotazy chodia proti `logs.http_log_agg` (SummingMergeTree) s kľúčom `(resource_id, response_status, cache_status, remote_addr)` → čítanie je O(partícií) a radené podľa kľúča.
  - Typické dotazy (sum bytes, count) pre dni/týždne by mali byť v sekundách (nízke jednotky) na single-node ClickHouse (závisí od počtu skupín).

- Odhad miesta na disku (príkladový výpočet):
  - Nech priemerne 1 000 správ/s, retenčná doba 30 dní.
  - Priemerná veľkosť riadku v ClickHouse (stĺpce zadané, nízka kardinalita pre `cache_status`/`method`) ≈ 80–160 B/riado k (silne závislé od `url` a `remote_addr`). Poviem konzervatívne 150 B/riadok po kompresii.
  - Dátová sadzba: 1 000 r/s × 150 B ≈ 150 kB/s ≈ 12.96 GB/deň.
  - 30 dní ≈ 389 GB RAW. Po kompresii CH (LZ4) môže byť nižšia; ak `url` dlhé a rôznorodé, môže byť vyššia. Agregovaná tabuľka býva rádovo menšia (percentá až jednotky %).
  - Vzorec: `disk ≈ rate_rps × size_per_row_bytes × seconds(retention)`.

### Limity a možnosti rozšírenia
- Rate-limit 1 req/min je úzke hrdlo → veľké batch-e, latencia ~1 min. Riešenia:
  - Zdvihnúť limit (napr. 60 req/min) a flushovať menšie dávky raz za sekundu.
  - Paralené shardovanie: viac proxy + viac CH nódov + hash-partition podľa `resource_id`.
  - Použiť ClickHouse `INSERT SELECT` z dočasného local bufferu (napr. Kafka engine v CH) a rate-limit uplatniť až na merge/aggregáciu.

- Deduplikácia:
  - `ReplacingMergeTree` + stabilný `version`/`dedup_token` (napr. `(topic, partition, offset)` alebo hash z celého záznamu). 
  - Pri RAW tabuľke zachovať originál a deduplikovať až v zobrazeniach/AGG.

- Backpressure a pamäť:
  - Aplikácia čaká pri plnom batchi do ďalšieho flush okna, aby nerástla pamäť.
  - Možno doplniť on‑disk buffer (napr. lokálna queue) pre extrémny prietok.

- Observabilita a operatíva:
  - Export metrik (Prometheus): veľkosť batchu, flush trvanie, retry count, Kafka lag, commit latency.
  - Struktúrované logy + sampling.

### Poznámky k behu v cudzom prostredí s Dockerom
- Jednorazové codegen/`docker build` nepublikuje porty → neovplyvní existujúce kontajnery (okrem CPU/disku).
- Spustenie celej `docker-compose` infra môže kolidovať:
  - Porty: 9092/9101/3000/9090/5556/4000/8123/9000/9009/8124.
  - `container_name` v compose sú pevné → môžu zrážať existujúce kontajnery rovnakého mena. 
  - Odporúčanie: na cudzej mašine nespúšťať celú infra; iba jednorazové codegen alebo build v izolovanom kontajneri.

### Ako generovať Cap’n Proto bez lokálnej inštalácie
Bezpečný jednorazový príkaz (nepublikuje porty, len vytvorí `src/generated`):
```
docker run --rm -v %cd%:/work -w /work ubuntu:22.04 bash -lc "apt-get update && apt-get install -y capnproto && mkdir -p src/generated && capnp compile -o c++:src/generated src/http_log.capnp"
```
Na Linux/macOS zmeň `%cd%` na `$(pwd)`.

