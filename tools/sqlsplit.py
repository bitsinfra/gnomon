"""Split a PostgreSQL script into top-level statements (quotes, dollar quotes, comments aware)."""
import re, sys

def split(sql):
    out, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == '-' and sql.startswith('--', i):
            j = sql.find('\n', i); j = n if j < 0 else j
            buf.append(sql[i:j]); i = j; continue
        if c == '/' and sql.startswith('/*', i):
            j = sql.find('*/', i + 2); j = n if j < 0 else j + 2
            buf.append(sql[i:j]); i = j; continue
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'" and j + 1 < n and sql[j + 1] == "'": j += 2; continue
                if sql[j] == "'": break
                j += 1
            buf.append(sql[i:j + 1]); i = j + 1; continue
        if c == '"':
            j = sql.find('"', i + 1); buf.append(sql[i:j + 1]); i = j + 1; continue
        if c == '$':
            m = re.match(r'\$([A-Za-z_][A-Za-z_0-9]*)?\$', sql[i:])
            if m:
                tag = m.group(0); j = sql.find(tag, i + len(tag))
                if j < 0: raise ValueError('unterminated dollar quote ' + tag)
                buf.append(sql[i:j + len(tag)]); i = j + len(tag); continue
        if c == ';':
            buf.append(';'); out.append(''.join(buf)); buf = []; i += 1; continue
        buf.append(c); i += 1
    rest = ''.join(buf)
    if rest.strip(): out.append(rest)
    return out

def head(stmt):
    """The statement's first words, comments stripped, lowercased."""
    s = re.sub(r'--[^\n]*', '', stmt)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return ' '.join(s.split()).lower()

if __name__ == '__main__':
    from collections import Counter
    c = Counter()
    for st in split(open(sys.argv[1]).read()):
        h = head(st)
        if not h: continue
        w = h.split()
        k = ' '.join(w[:3]) if w[0] in ('create', 'alter', 'drop', 'comment') else w[0]
        c[k] += 1
    for k, v in c.most_common(): print(v, k)
