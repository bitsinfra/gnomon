package archive

// Crypto-shredding of archives. For a table with a data subject
// (gnomon.set_subject), the archiver encrypts the declared columns of every archived version with
// AES-256-GCM under the subject's key, kept only in the database, and writes the subject in a
// column of its own (gn_subject). Restores and thaws decrypt; once gnomon.erase_subject has
// deleted a key, that subject's values come back NULL, with no rewrite of the file (a store with
// object lock cannot rewrite one).

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

const encPrefix = "gnomon:enc:v1:"

// Crypto is a table's archive encryption: the subject column and the encrypted columns, by their
// names in the version table.
type Crypto struct {
	Table          string   `json:"table"`
	Keys           []string `json:"keys"`
	Subject        string   `json:"subject"`
	SubjectStorage string   `json:"subject_storage"`
	Columns        []struct {
		Name    string `json:"name"`
		Storage string `json:"storage"`
	} `json:"columns"`
	keys map[string][]byte
}

func loadCrypto(ctx context.Context, c *pgx.Conn, table string) (*Crypto, error) {
	var raw *string
	if err := c.QueryRow(ctx, "select gnomon.archive_crypto($1::regclass)::text", table).Scan(&raw); err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, nil
	}
	var cr Crypto
	if err := json.Unmarshal([]byte(*raw), &cr); err != nil {
		return nil, err
	}
	cr.keys = map[string][]byte{}
	return &cr, nil
}

func (cr *Crypto) encrypted(storage string) bool {
	for _, c := range cr.Columns {
		if c.Storage == storage {
			return true
		}
	}
	return false
}

// key returns a subject's key, made when the subject has none yet.
func (cr *Crypto) key(ctx context.Context, c *pgx.Conn, subject string, create bool) ([]byte, error) {
	if k, ok := cr.keys[subject]; ok {
		return k, nil
	}
	rows, err := c.Query(ctx, "select subject, key from gnomon.subject_keys($1::regclass, $2::text[], $3)", cr.Table, []string{subject}, create)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var k []byte
	for rows.Next() {
		var s string
		if err := rows.Scan(&s, &k); err != nil {
			return nil, err
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	cr.keys[subject] = k // nil: erased
	return k, nil
}

// prefetch fetches (and makes) the keys of every subject a partition's versions name, before
// the partition is read: the connection cannot run a query while it streams rows.
func (cr *Crypto) prefetch(ctx context.Context, c *pgx.Conn, rel string) error {
	rows, err := c.Query(ctx, fmt.Sprintf("select distinct coalesce(%s::text, '') from %s", pgx.Identifier{cr.SubjectStorage}.Sanitize(), rel))
	if err != nil {
		return err
	}
	subjects := []string{""}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			rows.Close()
			return err
		}
		subjects = append(subjects, s)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	krows, err := c.Query(ctx, "select subject, key from gnomon.subject_keys($1::regclass, $2::text[], true)", cr.Table, subjects)
	if err != nil {
		return err
	}
	defer krows.Close()
	for _, s := range subjects {
		cr.keys[s] = nil // erased unless a key comes back
	}
	for krows.Next() {
		var s string
		var k []byte
		if err := krows.Scan(&s, &k); err != nil {
			return err
		}
		cr.keys[s] = k
	}
	return krows.Err()
}

func aad(table, column, subject string) []byte {
	return []byte(table + "\x00" + column + "\x00" + subject)
}

func seal(key []byte, plain, ad []byte) (string, error) {
	blk, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	g, err := cipher.NewGCM(blk)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, g.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return encPrefix + base64.RawStdEncoding.EncodeToString(g.Seal(nonce, nonce, plain, ad)), nil
}

func open(key []byte, sealed string, ad []byte) (string, error) {
	b, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(sealed, encPrefix))
	if err != nil {
		return "", err
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	g, err := cipher.NewGCM(blk)
	if err != nil {
		return "", err
	}
	if len(b) < g.NonceSize() {
		return "", errors.New("archive: encrypted value too short")
	}
	p, err := g.Open(nil, b[:g.NonceSize()], b[g.NonceSize():], ad)
	return string(p), err
}

// decryptRows opens the encrypted values of an archive's rows in place; a value whose subject
// key was erased becomes NULL.
func decryptRows(ctx context.Context, c *pgx.Conn, table string, rows []map[string]*string) error {
	var cr *Crypto
	for _, r := range rows {
		subj := ""
		if s := r["gn_subject"]; s != nil {
			subj = *s
		}
		for col, v := range r {
			if v == nil || !strings.HasPrefix(*v, encPrefix) {
				continue
			}
			if cr == nil {
				var err error
				if cr, err = loadCrypto(ctx, c, table); err != nil {
					return err
				}
				if cr == nil {
					cr = &Crypto{Table: table, keys: map[string][]byte{}}
				}
			}
			k, err := cr.key(ctx, c, subj, false)
			if err != nil {
				return err
			}
			if k == nil {
				r[col] = nil
				continue
			}
			p, err := open(k, *v, aad(cr.Table, col, subj))
			if err != nil {
				return fmt.Errorf("archive: decrypting %s of subject %q: %w", col, subj, err)
			}
			r[col] = &p
		}
		delete(r, "gn_subject")
	}
	return nil
}
