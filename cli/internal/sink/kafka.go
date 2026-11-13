package sink

// A Kafka producer with no client library, so the binary stays static: Metadata
// v1 for the topic's partitions and their leaders, InitProducerId v0 for an idempotent producer,
// and Produce v3 with v2 record batches (CRC-32C). A message's key is the row's key, so one row's
// changes stay in order on one partition (chosen as Kafka's default partitioner does, murmur2);
// the change id travels in a header (gnomon-id).
//
// Exactly once per partition: the producer id, its epoch and the next sequence of every
// partition are the sink's state (gnomon.sink.state), saved in the delivery's transaction. A
// delivery that fails after Kafka appended a batch (an acknowledgement lost) is sent again with
// the same sequences, which the broker recognises and does not append twice.

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

type kafkaState struct {
	ProducerID int64            `json:"producer_id"`
	Epoch      int16            `json:"epoch"`
	Seq        map[string]int32 `json:"seq"`
	Brokers    string           `json:"brokers"`
}

// ---- wire encoding

type kbuf struct{ b []byte }

func (k *kbuf) i8(v int8)   { k.b = append(k.b, byte(v)) }
func (k *kbuf) i16(v int16) { k.b = binary.BigEndian.AppendUint16(k.b, uint16(v)) }
func (k *kbuf) i32(v int32) { k.b = binary.BigEndian.AppendUint32(k.b, uint32(v)) }
func (k *kbuf) i64(v int64) { k.b = binary.BigEndian.AppendUint64(k.b, uint64(v)) }
func (k *kbuf) str(s string) {
	k.i16(int16(len(s)))
	k.b = append(k.b, s...)
}
func (k *kbuf) nullStr() { k.i16(-1) }
func (k *kbuf) bytes(p []byte) {
	k.i32(int32(len(p)))
	k.b = append(k.b, p...)
}
func (k *kbuf) varint(v int64) { k.b = binary.AppendVarint(k.b, v) } // zigzag, as Kafka's records use
func (k *kbuf) varBytes(p []byte) {
	if p == nil {
		k.varint(-1)
		return
	}
	k.varint(int64(len(p)))
	k.b = append(k.b, p...)
}

type kread struct {
	b   []byte
	off int
	err error
}

func (r *kread) need(n int) bool {
	if r.err != nil {
		return false
	}
	if r.off+n > len(r.b) {
		r.err = io.ErrUnexpectedEOF
		return false
	}
	return true
}
func (r *kread) i8() int8 {
	if !r.need(1) {
		return 0
	}
	r.off++
	return int8(r.b[r.off-1])
}
func (r *kread) i16() int16 {
	if !r.need(2) {
		return 0
	}
	r.off += 2
	return int16(binary.BigEndian.Uint16(r.b[r.off-2:]))
}
func (r *kread) i32() int32 {
	if !r.need(4) {
		return 0
	}
	r.off += 4
	return int32(binary.BigEndian.Uint32(r.b[r.off-4:]))
}
func (r *kread) i64() int64 {
	if !r.need(8) {
		return 0
	}
	r.off += 8
	return int64(binary.BigEndian.Uint64(r.b[r.off-8:]))
}
func (r *kread) str() string {
	n := int(r.i16())
	if n < 0 || !r.need(n) {
		return ""
	}
	r.off += n
	return string(r.b[r.off-n : r.off])
}
func (r *kread) bytes() []byte {
	n := int(r.i32())
	if n < 0 || !r.need(n) {
		return nil
	}
	r.off += n
	return r.b[r.off-n : r.off]
}
func (r *kread) varint() int64 {
	if r.err != nil {
		return 0
	}
	v, n := binary.Varint(r.b[r.off:])
	if n <= 0 {
		r.err = io.ErrUnexpectedEOF
		return 0
	}
	r.off += n
	return v
}
func (r *kread) varBytes() []byte {
	n := int(r.varint())
	if n < 0 || !r.need(n) {
		return nil
	}
	r.off += n
	return r.b[r.off-n : r.off]
}

// ---- connection

type kconn struct {
	c    net.Conn
	rd   *bufio.Reader
	corr int32
}

func kdial(ctx context.Context, addr string) (*kconn, error) {
	d := net.Dialer{Timeout: 5 * time.Second}
	c, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(30 * time.Second))
	return &kconn{c: c, rd: bufio.NewReader(c)}, nil
}

func (k *kconn) close() { k.c.Close() }

// request sends one request (header v1) and returns the response body after its correlation id.
func (k *kconn) request(api, version int16, body []byte) ([]byte, error) {
	k.corr++
	var h kbuf
	h.i16(api)
	h.i16(version)
	h.i32(k.corr)
	h.str("gnomon-sink")
	msg := append(h.b, body...)
	frame := binary.BigEndian.AppendUint32(nil, uint32(len(msg)))
	if _, err := k.c.Write(append(frame, msg...)); err != nil {
		return nil, err
	}
	var size [4]byte
	if _, err := io.ReadFull(k.rd, size[:]); err != nil {
		return nil, err
	}
	resp := make([]byte, binary.BigEndian.Uint32(size[:]))
	if _, err := io.ReadFull(k.rd, resp); err != nil {
		return nil, err
	}
	if len(resp) < 4 || int32(binary.BigEndian.Uint32(resp)) != k.corr {
		return nil, errors.New("kafka: response out of order")
	}
	return resp[4:], nil
}

// ---- the three requests

type kmeta struct {
	brokers    map[int32]string
	partitions []int32
	leaders    map[int32]int32
}

// Metadata v4: the oldest version Kafka 4 still serves (KIP-896 removed v0-v3), and one every
// broker since 0.11 (the first with idempotent producers) understands.
func kafkaMetadata(k *kconn, topic string) (*kmeta, error) {
	var b kbuf
	b.i32(1)
	b.str(topic)
	b.i8(0) // allow_auto_topic_creation: no, a missing topic is an error to report
	resp, err := k.request(3, 4, b.b)
	if err != nil {
		return nil, err
	}
	r := &kread{b: resp}
	m := &kmeta{brokers: map[int32]string{}, leaders: map[int32]int32{}}
	_ = r.i32() // throttle_time_ms
	for n := r.i32(); n > 0; n-- {
		id := r.i32()
		host := r.str()
		port := r.i32()
		_ = r.str() // rack (nullable)
		m.brokers[id] = net.JoinHostPort(host, strconv.Itoa(int(port)))
	}
	_ = r.str() // cluster_id (nullable)
	_ = r.i32() // controller
	for n := r.i32(); n > 0; n-- {
		code := r.i16()
		name := r.str()
		_ = r.i8()
		np := r.i32()
		if code != 0 && name == topic {
			return nil, fmt.Errorf("kafka: topic %s: error %d (create the topic first)", topic, code)
		}
		for ; np > 0; np-- {
			_ = r.i16()
			p := r.i32()
			leader := r.i32()
			for nr := r.i32(); nr > 0; nr-- {
				_ = r.i32()
			}
			for ni := r.i32(); ni > 0; ni-- {
				_ = r.i32()
			}
			if name == topic {
				m.partitions = append(m.partitions, p)
				m.leaders[p] = leader
			}
		}
	}
	if r.err != nil {
		return nil, fmt.Errorf("kafka: metadata: %w", r.err)
	}
	if len(m.partitions) == 0 {
		return nil, fmt.Errorf("kafka: topic %s has no partitions (create it first)", topic)
	}
	return m, nil
}

// InitProducerId, retried while the broker's coordinator is still loading or not yet available
// (errors 14 and 15, as on a broker that has just started), as Kafka's own clients do.
func kafkaInitProducer(k *kconn) (int64, int16, error) {
	var b kbuf
	b.nullStr()
	b.i32(60000)
	for attempt := 0; ; attempt++ {
		resp, err := k.request(22, 0, b.b)
		if err != nil {
			return 0, 0, err
		}
		r := &kread{b: resp}
		_ = r.i32()
		code := r.i16()
		pid := r.i64()
		epoch := r.i16()
		if r.err != nil {
			return 0, 0, r.err
		}
		if (code == 14 || code == 15) && attempt < 50 {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if code != 0 {
			return 0, 0, fmt.Errorf("kafka: InitProducerId: error %d", code)
		}
		return pid, epoch, nil
	}
}

type krec struct {
	key, value []byte
	headers    [][2]string
}

// recordBatch encodes a v2 record batch for an idempotent producer.
func recordBatch(pid int64, epoch int16, baseSeq int32, recs []krec, ts int64) []byte {
	var a kbuf
	a.i16(0) // attributes: no compression, not transactional
	a.i32(int32(len(recs) - 1))
	a.i64(ts)
	a.i64(ts)
	a.i64(pid)
	a.i16(epoch)
	a.i32(baseSeq)
	a.i32(int32(len(recs)))
	for i, rc := range recs {
		var r kbuf
		r.i8(0)
		r.varint(0)
		r.varint(int64(i))
		r.varBytes(rc.key)
		r.varBytes(rc.value)
		r.varint(int64(len(rc.headers)))
		for _, h := range rc.headers {
			r.varBytes([]byte(h[0]))
			r.varBytes([]byte(h[1]))
		}
		a.varint(int64(len(r.b)))
		a.b = append(a.b, r.b...)
	}
	var out kbuf
	out.i64(0)                           // base offset
	out.i32(int32(4 + 1 + 4 + len(a.b))) // batch length: leader epoch, magic, crc, the rest
	out.i32(-1)                          // partition leader epoch
	out.i8(2)                            // magic
	out.b = binary.BigEndian.AppendUint32(out.b, crc32.Checksum(a.b, castagnoli))
	out.b = append(out.b, a.b...)
	return out.b
}

const (
	kafkaDuplicateSequence = 46
)

func kafkaProduce(k *kconn, topic string, part int32, batch []byte) error {
	var b kbuf
	b.nullStr()
	b.i16(-1) // acks: all in-sync replicas
	b.i32(30000)
	b.i32(1)
	b.str(topic)
	b.i32(1)
	b.i32(part)
	b.bytes(batch)
	resp, err := k.request(0, 3, b.b)
	if err != nil {
		return err
	}
	r := &kread{b: resp}
	for n := r.i32(); n > 0; n-- {
		_ = r.str()
		for np := r.i32(); np > 0; np-- {
			_ = r.i32()
			code := r.i16()
			_ = r.i64()
			_ = r.i64()
			if code != 0 && code != kafkaDuplicateSequence {
				return fmt.Errorf("kafka: produce to %s/%d: error %d", topic, part, code)
			}
		}
	}
	return r.err
}

// murmur2 is Kafka's default partitioner hash (org.apache.kafka.common.utils.Utils.murmur2).
func murmur2(data []byte) int32 {
	const m = uint32(0x5bd1e995)
	const r = 24
	length := len(data)
	h := uint32(0x9747b28c) ^ uint32(length)
	for i := 0; i+4 <= length; i += 4 {
		k := uint32(data[i]) | uint32(data[i+1])<<8 | uint32(data[i+2])<<16 | uint32(data[i+3])<<24
		k *= m
		k ^= k >> r
		k *= m
		h *= m
		h ^= k
	}
	tail := length &^ 3
	switch length % 4 {
	case 3:
		h ^= uint32(data[tail+2]) << 16
		fallthrough
	case 2:
		h ^= uint32(data[tail+1]) << 8
		fallthrough
	case 1:
		h ^= uint32(data[tail])
		h *= m
	}
	h ^= h >> 13
	h *= m
	h ^= h >> 15
	return int32(h)
}

// KafkaPartition is the partition Kafka's default partitioner picks for a key.
func KafkaPartition(key []byte, n int) int32 {
	return int32(int(murmur2(key)&0x7fffffff) % n)
}

func kafkaBrokers(s sinkRow) []string {
	var out []string
	for _, b := range strings.Split(fmt.Sprint(s.config["brokers"]), ",") {
		if b = strings.TrimSpace(b); b != "" && b != "<nil>" {
			out = append(out, b)
		}
	}
	return out
}

func kafkaTopic(s sinkRow) string {
	t := fmt.Sprint(s.config["topic"])
	if t == "" || t == "<nil>" {
		return "gnomon.changes"
	}
	return t
}

func kafkaConnectAny(ctx context.Context, brokers []string) (*kconn, error) {
	var last error
	for _, b := range brokers {
		k, err := kdial(ctx, b)
		if err == nil {
			return k, nil
		}
		last = err
	}
	if last == nil {
		last = errors.New("kafka: no brokers configured (config.brokers)")
	}
	return nil, last
}

// kafkaEnsureProducer gives the sink a producer id before anything is sent, saved on its own,
// so a batch is never sent under two producer ids.
func kafkaEnsureProducer(ctx context.Context, s sinkRow, save func(kafkaState) error) (kafkaState, error) {
	var st kafkaState
	if b, err := json.Marshal(s.state); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	brokers := kafkaBrokers(s)
	if st.ProducerID != 0 && st.Brokers == strings.Join(brokers, ",") {
		return st, nil
	}
	k, err := kafkaConnectAny(ctx, brokers)
	if err != nil {
		return st, err
	}
	defer k.close()
	pid, epoch, err := kafkaInitProducer(k)
	if err != nil {
		return st, err
	}
	st = kafkaState{ProducerID: pid, Epoch: epoch, Seq: map[string]int32{}, Brokers: strings.Join(brokers, ",")}
	return st, save(st)
}

// kafkaPublish sends one batch of changes, partitioned by row key, and returns the state to save
// with the batch's transaction.
func kafkaPublish(ctx context.Context, s sinkRow, st kafkaState, ch []change, msgs []map[string]any) (kafkaState, error) {
	topic := kafkaTopic(s)
	k, err := kafkaConnectAny(ctx, kafkaBrokers(s))
	if err != nil {
		return st, err
	}
	meta, err := kafkaMetadata(k, topic)
	k.close()
	if err != nil {
		return st, err
	}
	byPart := map[int32][]krec{}
	var order []int32
	for i, m := range msgs {
		body, _ := json.Marshal(m)
		key := []byte(keyText(ch[i].Key))
		p := meta.partitions[KafkaPartition(key, len(meta.partitions))]
		if _, ok := byPart[p]; !ok {
			order = append(order, p)
		}
		byPart[p] = append(byPart[p], krec{key: key, value: body, headers: [][2]string{{"gnomon-id", ch[i].ID}, {"gnomon-table", ch[i].Tbl}}})
	}
	conns := map[int32]*kconn{}
	defer func() {
		for _, c := range conns {
			c.close()
		}
	}()
	next := kafkaState{ProducerID: st.ProducerID, Epoch: st.Epoch, Brokers: st.Brokers, Seq: map[string]int32{}}
	for p, v := range st.Seq {
		next.Seq[p] = v
	}
	ts := time.Now().UnixMilli()
	for _, p := range order {
		leader := meta.leaders[p]
		c := conns[leader]
		if c == nil {
			addr, ok := meta.brokers[leader]
			if !ok {
				return st, fmt.Errorf("kafka: no address for broker %d", leader)
			}
			if c, err = kdial(ctx, addr); err != nil {
				return st, err
			}
			conns[leader] = c
		}
		key := strconv.Itoa(int(p))
		recs := byPart[p]
		if err := kafkaProduce(c, topic, p, recordBatch(st.ProducerID, st.Epoch, next.Seq[key], recs, ts)); err != nil {
			return st, err
		}
		next.Seq[key] += int32(len(recs))
	}
	return next, nil
}
