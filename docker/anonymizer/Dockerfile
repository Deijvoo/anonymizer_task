FROM ubuntu:22.04 as build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential cmake pkg-config git curl ca-certificates \
    librdkafka-dev libcurl4-openssl-dev libcapnp-dev capnproto \
    libspdlog-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build --config Release -j

FROM ubuntu:22.04 as runtime
RUN apt-get update && apt-get install -y \
    librdkafka1 librdkafka++1 libcurl4 libcapnp-dev libspdlog1 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/build/anonymizer /usr/local/bin/anonymizer

ENV KAFKA_BROKERS="broker:29092" \
    CLICKHOUSE_URL="http://ch-proxy:8124/?query=INSERT%20INTO%20logs.http_log%20FORMAT%20JSONEachRow"

ENTRYPOINT ["/usr/local/bin/anonymizer"]
