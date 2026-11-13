package archive_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/archive"
)

// The signing example in the Amazon S3 documentation ("Signature Version 4: GET Object").
func TestSignV4AWSExample(t *testing.T) {
	req, _ := http.NewRequest("GET", "https://examplebucket.s3.amazonaws.com/test.txt", nil)
	req.Header.Set("Range", "bytes=0-9")
	cfg := archive.S3Config{AccessKey: "AKIAIOSFODNN7EXAMPLE", SecretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", Region: "us-east-1"}
	archive.SignV4(req, nil, cfg, time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC))
	want := "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
		"SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
		"Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
	if got := req.Header.Get("Authorization"); got != want {
		t.Fatalf("Authorization\n got %s\nwant %s", got, want)
	}
}

// fakeS3 keeps objects in memory and accepts only requests whose signature it can recompute
// from what it received (so what the client signs is what it sends).
type fakeS3 struct {
	mu      sync.Mutex
	objects map[string][]byte
	secret  string
	t       *testing.T
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	auth := r.Header.Get("Authorization")
	check, _ := http.NewRequest(r.Method, "http://"+r.Host+r.URL.RequestURI(), nil)
	for _, h := range []string{"X-Amz-Date", "X-Amz-Security-Token"} {
		if v := r.Header.Get(h); v != "" {
			check.Header.Set(h, v)
		}
	}
	day, _ := time.Parse("20060102T150405Z", r.Header.Get("X-Amz-Date"))
	archive.SignV4(check, body, archive.S3Config{AccessKey: "AKTEST", SecretKey: f.secret, Region: "us-test-1",
		SessionToken: r.Header.Get("X-Amz-Security-Token")}, day)
	if auth == "" || auth != check.Header.Get("Authorization") {
		f.t.Errorf("bad signature for %s %s:\n got %s\nwant %s", r.Method, r.URL, auth, check.Header.Get("Authorization"))
		http.Error(w, "SignatureDoesNotMatch", http.StatusForbidden)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.Method {
	case http.MethodPut:
		f.objects[r.URL.Path] = body
	case http.MethodGet:
		b, ok := f.objects[r.URL.Path]
		if !ok {
			http.Error(w, "NoSuchKey", http.StatusNotFound)
			return
		}
		_, _ = w.Write(b)
	default:
		http.Error(w, "not implemented", http.StatusNotImplemented)
	}
}

// The archive round trip with s3:// on an S3-compatible endpoint (path-style requests).
func TestArchiveRoundTripS3(t *testing.T) {
	fake := &fakeS3{objects: map[string][]byte{}, secret: "s3cr3t", t: t}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	t.Setenv("AWS_ACCESS_KEY_ID", "AKTEST")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "s3cr3t")
	t.Setenv("AWS_SESSION_TOKEN", "tok")
	t.Setenv("AWS_REGION", "us-test-1")
	t.Setenv("AWS_ENDPOINT_URL", srv.URL)
	list := func() []string {
		fake.mu.Lock()
		defer fake.mu.Unlock()
		var out []string
		for k := range fake.objects {
			if strings.HasPrefix(k, "/archive-bucket/gnomon/") {
				out = append(out, k)
			}
		}
		sort.Strings(out)
		return out
	}
	read := func(key string) (*archive.File, error) {
		fake.mu.Lock()
		b := fake.objects[key]
		fake.mu.Unlock()
		f, err := os.CreateTemp(t.TempDir(), "*.parquet")
		if err != nil {
			return nil, err
		}
		if _, err := f.Write(b); err != nil {
			return nil, err
		}
		f.Close()
		return archive.ReadParquet(f.Name())
	}
	roundTrip(t, "s3://archive-bucket/gnomon", list, read)
}

func TestS3NeedsCredentials(t *testing.T) {
	t.Setenv("AWS_ACCESS_KEY_ID", "")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "")
	if _, err := archive.OpenStore("s3://b/p"); err == nil || !strings.Contains(err.Error(), "AWS_ACCESS_KEY_ID") {
		t.Fatalf("expected a credentials error, got %v", err)
	}
}
