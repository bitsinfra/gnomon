package archive

// Object storage for archives: Amazon S3 and anything that speaks its API (MinIO, Ceph, R2, and
// Google Cloud Storage through its XML API with HMAC keys), with AWS Signature Version 4 and the
// standard library only.
//
//	s3://bucket/prefix   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN (optional),
//	                     AWS_REGION (default us-east-1), AWS_ENDPOINT_URL for other S3 servers
//	                     (path-style requests, e.g. http://localhost:9000)
//	gs://bucket/prefix   the same with endpoint https://storage.googleapis.com and region auto,
//	                     using GCS HMAC keys as the access key pair

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"sort"
	"strings"
	"time"
)

// S3Config holds what a request needs; FromEnv fills it.
type S3Config struct {
	AccessKey, SecretKey, SessionToken string
	Region                             string
	Endpoint                           string // empty: virtual-hosted AWS (https://<bucket>.s3.<region>.amazonaws.com)
	Client                             *http.Client
	Now                                func() time.Time
}

func s3ConfigFromEnv(scheme string) (S3Config, error) {
	c := S3Config{
		AccessKey:    os.Getenv("AWS_ACCESS_KEY_ID"),
		SecretKey:    os.Getenv("AWS_SECRET_ACCESS_KEY"),
		SessionToken: os.Getenv("AWS_SESSION_TOKEN"),
		Region:       os.Getenv("AWS_REGION"),
		Endpoint:     os.Getenv("AWS_ENDPOINT_URL"),
	}
	if c.Region == "" {
		c.Region = os.Getenv("AWS_DEFAULT_REGION")
	}
	if scheme == "gs" {
		if c.Endpoint == "" {
			c.Endpoint = "https://storage.googleapis.com"
		}
		if c.Region == "" {
			c.Region = "auto"
		}
	}
	if c.Region == "" {
		c.Region = "us-east-1"
	}
	if c.AccessKey == "" || c.SecretKey == "" {
		return c, fmt.Errorf("%s:// archives need AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (for gs://, GCS HMAC keys)", scheme)
	}
	return c, nil
}

type s3Store struct {
	cfg    S3Config
	scheme string
	bucket string
	prefix string
}

func newS3Store(uri string, cfg S3Config) (*s3Store, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", uri, err)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("%s: expected %s://bucket/prefix", uri, u.Scheme)
	}
	return &s3Store{cfg: cfg, scheme: u.Scheme, bucket: u.Host, prefix: strings.Trim(u.Path, "/")}, nil
}

func (s *s3Store) key(name string) string {
	if s.prefix == "" {
		return name
	}
	return s.prefix + "/" + name
}

// objectURL is where a key lives: path-style on a custom endpoint, virtual-hosted on AWS.
func (s *s3Store) objectURL(key string) *url.URL {
	esc := (&url.URL{Path: "/" + key}).EscapedPath()
	if s.cfg.Endpoint != "" {
		u, _ := url.Parse(strings.TrimRight(s.cfg.Endpoint, "/"))
		u.Path = "/" + s.bucket + "/" + key
		u.RawPath = "/" + s.bucket + esc
		return u
	}
	return &url.URL{Scheme: "https", Host: s.bucket + ".s3." + s.cfg.Region + ".amazonaws.com", Path: "/" + key, RawPath: esc}
}

func (s *s3Store) do(method, key string, body []byte) (*http.Response, error) {
	u := s.objectURL(key)
	req, err := http.NewRequest(method, u.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.ContentLength = int64(len(body))
	SignV4(req, body, s.cfg, s.cfg.now())
	client := s.cfg.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		return nil, fmt.Errorf("%s %s: %s: %s", method, u.Redacted(), resp.Status, strings.TrimSpace(string(msg)))
	}
	return resp, nil
}

// Create buffers the object in a temporary file and uploads it on Close.
func (s *s3Store) Create(name string) (io.WriteCloser, string, error) {
	f, err := os.CreateTemp("", "gnomon-archive-*.parquet")
	if err != nil {
		return nil, "", err
	}
	key := s.key(name)
	return &s3Upload{f: f, s: s, key: key}, s.scheme + "://" + s.bucket + "/" + key, nil
}

type s3Upload struct {
	f   *os.File
	s   *s3Store
	key string
}

func (u *s3Upload) Write(p []byte) (int, error) { return u.f.Write(p) }

func (u *s3Upload) Close() error {
	defer os.Remove(u.f.Name())
	if err := u.f.Close(); err != nil {
		return err
	}
	body, err := os.ReadFile(u.f.Name())
	if err != nil {
		return err
	}
	resp, err := u.s.do(http.MethodPut, u.key, body)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// Fetch downloads an object to a temporary file.
func (s *s3Store) Fetch(uri string) (string, func(), error) {
	u, err := url.Parse(uri)
	if err != nil {
		return "", nil, err
	}
	resp, err := s.do(http.MethodGet, strings.TrimPrefix(u.Path, "/"), nil)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	f, err := os.CreateTemp("", "gnomon-archive-*.parquet")
	if err != nil {
		return "", nil, err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", nil, err
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return "", nil, err
	}
	return f.Name(), func() { os.Remove(f.Name()) }, nil
}

// Put uploads a local file to an archive URI (erase-archives rewrites files in place).
func (s *s3Store) Put(uri, local string) error {
	u, err := url.Parse(uri)
	if err != nil {
		return err
	}
	body, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	resp, err := s.do(http.MethodPut, strings.TrimPrefix(u.Path, "/"), body)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func (c S3Config) now() time.Time {
	if c.Now != nil {
		return c.Now().UTC()
	}
	return time.Now().UTC()
}

// SignV4 adds AWS Signature Version 4 headers (service s3) to req.
func SignV4(req *http.Request, body []byte, cfg S3Config, t time.Time) {
	amzDate := t.UTC().Format("20060102T150405Z")
	day := amzDate[:8]
	sum := sha256.Sum256(body)
	payload := hex.EncodeToString(sum[:])
	if req.Header.Get("X-Amz-Content-Sha256") != "" {
		payload = req.Header.Get("X-Amz-Content-Sha256")
	}
	req.Header.Set("X-Amz-Content-Sha256", payload)
	req.Header.Set("X-Amz-Date", amzDate)
	if cfg.SessionToken != "" {
		req.Header.Set("X-Amz-Security-Token", cfg.SessionToken)
	}
	host := req.Host
	if host == "" {
		host = req.URL.Host
	}

	// canonical headers: host and every x-amz-* header (plus any others already set), sorted
	names := []string{"host"}
	values := map[string]string{"host": host}
	for k, v := range req.Header {
		lk := strings.ToLower(k)
		if lk == "authorization" || lk == "user-agent" || lk == "content-length" {
			continue
		}
		names = append(names, lk)
		values[lk] = strings.Join(v, ",")
	}
	sort.Strings(names)
	var ch strings.Builder
	for _, n := range names {
		ch.WriteString(n + ":" + strings.TrimSpace(values[n]) + "\n")
	}
	signed := strings.Join(names, ";")

	canonical := strings.Join([]string{
		req.Method,
		canonicalPath(req.URL),
		canonicalQuery(req.URL),
		ch.String(),
		signed,
		payload,
	}, "\n")
	scope := day + "/" + cfg.Region + "/s3/aws4_request"
	h := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(h[:])
	k := hmacSHA256([]byte("AWS4"+cfg.SecretKey), day)
	k = hmacSHA256(k, cfg.Region)
	k = hmacSHA256(k, "s3")
	k = hmacSHA256(k, "aws4_request")
	sig := hex.EncodeToString(hmacSHA256(k, toSign))
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+cfg.AccessKey+"/"+scope+
		", SignedHeaders="+signed+", Signature="+sig)
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// S3 signs the path as sent, each segment URI-encoded once.
func canonicalPath(u *url.URL) string {
	p := u.EscapedPath()
	if p == "" {
		return "/"
	}
	segs := strings.Split(p, "/")
	for i, s := range segs {
		dec, err := url.PathUnescape(s)
		if err != nil {
			dec = s
		}
		segs[i] = awsEscape(dec)
	}
	return path.Clean("/"+strings.Join(segs, "/")) + map[bool]string{true: "/"}[strings.HasSuffix(p, "/") && p != "/"]
}

func canonicalQuery(u *url.URL) string {
	q := u.Query()
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		vs := q[k]
		sort.Strings(vs)
		for _, v := range vs {
			parts = append(parts, awsEscape(k)+"="+awsEscape(v))
		}
	}
	return strings.Join(parts, "&")
}

// awsEscape is RFC 3986 encoding: unreserved characters stay, everything else is %XX.
func awsEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
