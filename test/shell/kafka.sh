#!/usr/bin/env bash
# The Kafka sink against real brokers in Docker (apache/kafka, single-node KRaft): each version in
# KAFKA_VERSIONS gets a topic of three partitions, the sink delivers a table's changes to it
# (TestKafkaRealBroker, which also sends two batches again as after a lost acknowledgement), and
# Kafka's own console consumer reads the topic back: every change once, by its gnomon-id header.
# Skipped without Docker.
source "$(dirname "$0")/_lib.sh"
[ -n "${GNOMON_SKIP_EXTERNAL:-}" ] && { echo "skip: GNOMON_SKIP_EXTERNAL"; exit 0; }
command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "skip: no docker"; exit 0; }
VERSIONS=${KAFKA_VERSIONS:-3.9.1 4.1.0}
HP=${KAFKA_HOST_PORT:-59092}
NAME=gnomon-kafka-test
trap 'docker rm -f $NAME >/dev/null 2>&1 || true' EXIT
for v in $VERSIONS; do
  docker rm -f $NAME >/dev/null 2>&1 || true
  docker run -d --name $NAME -p 127.0.0.1:$HP:19092 \
    -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
    -e KAFKA_LISTENERS=PLAINTEXT://:9092,EXTERNAL://:19092,CONTROLLER://:9093 \
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092,EXTERNAL://localhost:$HP \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT \
    -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
    -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
    -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
    -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
    apache/kafka:$v >/dev/null
  kt() { docker exec $NAME /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
  for i in $(seq 1 60); do kt --list >/dev/null 2>&1 && break; sleep 1; done
  kt --create --topic gn.real --partitions 3 --replication-factor 1 >/dev/null || fail "kafka $v: creating the topic"
  out=$ROOT/build/test-out/kafka_$v.out
  (cd "$ROOT/cli" && GNOMON_TEST_REQUIRE=1 GNOMON_KAFKA_BROKERS=127.0.0.1:$HP GNOMON_KAFKA_TOPIC=gn.real \
     go test ./internal/sink/ -run TestKafkaRealBroker -count=1 -v) >"$out" 2>&1 || { tail -30 "$out"; fail "kafka $v: the sink"; }
  want=$(sed -n 's/.*KAFKA_WANT=\([0-9]*\).*/\1/p' "$out" | tail -1)
  [ -n "$want" ] || { tail -30 "$out"; fail "kafka $v: the test did not run"; }
  recs=$ROOT/build/test-out/kafka_$v.records
  docker exec $NAME /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic gn.real \
    --from-beginning --timeout-ms 10000 --property print.headers=true --property print.key=true >"$recs" 2>/dev/null || true
  n=$(grep -c 'gnomon-id:' "$recs" || true)
  ids=$(grep -o 'gnomon-id:[^,	]*' "$recs" | sort -u | wc -l | tr -d ' ')
  [ "$n" = "$want" ] && [ "$ids" = "$want" ] || fail "kafka $v: $n records, $ids distinct, want $want exactly once"
  echo "kafka $v: $want changes, each once"
done
echo ok
