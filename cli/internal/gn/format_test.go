package gn

import (
	"encoding/json"
	"net/netip"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// Values print as PostgreSQL prints them, and numbers stay exact.
func TestNormalize(t *testing.T) {
	u := [16]uint8{0x6f, 0x2c, 0x1c, 0x2e, 0x9a, 0x51, 0x4c, 0x43, 0x8d, 0x5e, 0x1e, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f}
	day := time.Date(2026, 11, 13, 0, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		v    any
		oid  uint32
		want string
	}{
		{u, pgtype.UUIDOID, "6f2c1c2e-9a51-4c43-8d5e-1e2b3c4d5e6f"},
		{[]any{u}, pgtype.UUIDArrayOID, `["6f2c1c2e-9a51-4c43-8d5e-1e2b3c4d5e6f"]`},
		{day, pgtype.DateOID, "2026-11-13"},
		{day, pgtype.TimestamptzOID, "2026-11-13T00:00:00Z"},
		{pgtype.Interval{Months: 14, Days: 3, Microseconds: 14706500000, Valid: true}, pgtype.IntervalOID, "1 year 2 mons 3 days 04:05:06.5"},
		{pgtype.Interval{Days: -1, Valid: true}, pgtype.IntervalOID, "-1 days"},
		{pgtype.Interval{Valid: true}, pgtype.IntervalOID, "00:00:00"},
		{pgtype.Time{Microseconds: 49501250000, Valid: true}, pgtype.TimeOID, "13:45:01.25"},
		{netip.MustParsePrefix("10.0.0.1/32"), pgtype.InetOID, "10.0.0.1"},
		{netip.MustParsePrefix("10.0.0.0/8"), pgtype.InetOID, "10.0.0.0/8"},
		{netip.MustParsePrefix("10.0.0.0/8"), pgtype.CIDROID, "10.0.0.0/8"},
	} {
		if got := Cell(normalize(c.v, c.oid)); got != c.want {
			t.Errorf("%T %v: %q, want %q", c.v, c.v, got, c.want)
		}
	}
	for s, want := range map[string]string{
		`{"id": 1234567890123456789, "p": 12.50}`: `{"id":1234567890123456789,"p":12.5}`,
		`[1, 99999999999999999999.5]`:             `[1,99999999999999999999.5]`,
	} {
		v, ok := exactJSON([]byte(s), false)
		b, _ := json.Marshal(v)
		if !ok || string(b) != want {
			t.Errorf("%s: %s, want %s", s, b, want)
		}
	}
	if v, ok := exactJSON(append([]byte{1}, `{"n": 9007199254740993}`...), true); !ok || Cell(v) != `{"n":9007199254740993}` {
		t.Errorf("binary jsonb: %v", v)
	}
}
