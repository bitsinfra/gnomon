package gn

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var dollarTag = regexp.MustCompile(`^\$([A-Za-z_][A-Za-z_0-9]*)?\$`)

// SplitSQL splits a script into top-level statements, aware of quotes, dollar quotes and
// comments (the Go port of tools/sqlsplit.py). Statements made only of comments are dropped.
func SplitSQL(sql string) []string {
	var out []string
	var buf strings.Builder
	n := len(sql)
	for i := 0; i < n; {
		c := sql[i]
		switch {
		case c == '-' && strings.HasPrefix(sql[i:], "--"):
			j := strings.IndexByte(sql[i:], '\n')
			if j < 0 {
				j = n - i
			}
			buf.WriteString(sql[i : i+j])
			i += j
			continue
		case c == '/' && strings.HasPrefix(sql[i:], "/*"):
			j := strings.Index(sql[i+2:], "*/")
			end := n
			if j >= 0 {
				end = i + 2 + j + 2
			}
			buf.WriteString(sql[i:end])
			i = end
			continue
		case c == '\'':
			j := i + 1
			for j < n {
				if sql[j] == '\'' && j+1 < n && sql[j+1] == '\'' {
					j += 2
					continue
				}
				if sql[j] == '\'' {
					break
				}
				j++
			}
			end := min(j+1, n)
			buf.WriteString(sql[i:end])
			i = end
			continue
		case c == '"':
			j := strings.IndexByte(sql[i+1:], '"')
			end := n
			if j >= 0 {
				end = i + 1 + j + 1
			}
			buf.WriteString(sql[i:end])
			i = end
			continue
		case c == '$':
			if m := dollarTag.FindString(sql[i:]); m != "" {
				j := strings.Index(sql[i+len(m):], m)
				end := n
				if j >= 0 {
					end = i + len(m) + j + len(m)
				}
				buf.WriteString(sql[i:end])
				i = end
				continue
			}
		case c == ';':
			buf.WriteByte(';')
			out = append(out, buf.String())
			buf.Reset()
			i++
			continue
		}
		buf.WriteByte(c)
		i++
	}
	if strings.TrimSpace(buf.String()) != "" {
		out = append(out, buf.String())
	}
	var keep []string
	for _, s := range out {
		if StatementHead(s) != "" {
			keep = append(keep, strings.TrimSpace(s))
		}
	}
	return keep
}

var lineComment = regexp.MustCompile(`--[^\n]*`)
var blockComment = regexp.MustCompile(`(?s)/\*.*?\*/`)

// StatementHead is a statement's words with comments stripped, lowercased.
func StatementHead(s string) string {
	s = lineComment.ReplaceAllString(s, "")
	s = blockComment.ReplaceAllString(s, "")
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// PostJSON posts a JSON body with an idempotency key and, with a secret, an HMAC-SHA256
// signature of the body (X-Gnomon-Signature: sha256=<hex>).
func PostJSON(ctx context.Context, url string, body []byte, secret, idempotencyKey string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	if secret != "" && secret != "<nil>" {
		m := hmac.New(sha256.New, []byte(secret))
		m.Write(body)
		req.Header.Set("X-Gnomon-Signature", "sha256="+hex.EncodeToString(m.Sum(nil)))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s answered %s", url, resp.Status)
	}
	return nil
}

func runGit(args ...string) (string, error) {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}

func gitCommonDir() (string, error) {
	out, err := runGit("rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return "", err
	}
	return filepath.Clean(strings.TrimSpace(out)), nil
}
