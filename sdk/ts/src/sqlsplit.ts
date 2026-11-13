// Top-level statements of a script, aware of quotes, dollar quotes and comments (the port of
// tools/sqlsplit.py). The SDK refuses a second statement in one call whatever the driver does.

export function splitSQL(sql: string): string[] {
  const out: string[] = [];
  let buf = "";
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const c = sql[i];
    if (c === "-" && sql.startsWith("--", i)) {
      let j = sql.indexOf("\n", i);
      if (j < 0) j = n;
      buf += sql.slice(i, j); i = j; continue;
    }
    if (c === "/" && sql.startsWith("/*", i)) {
      let j = sql.indexOf("*/", i + 2);
      j = j < 0 ? n : j + 2;
      buf += sql.slice(i, j); i = j; continue;
    }
    if (c === "'") {
      let j = i + 1;
      while (j < n) {
        if (sql[j] === "'" && sql[j + 1] === "'") { j += 2; continue; }
        if (sql[j] === "'") break;
        j++;
      }
      buf += sql.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === '"') {
      let j = sql.indexOf('"', i + 1);
      if (j < 0) j = n - 1;
      buf += sql.slice(i, j + 1); i = j + 1; continue;
    }
    if (c === "$") {
      const m = /^\$([A-Za-z_][A-Za-z_0-9]*)?\$/.exec(sql.slice(i));
      if (m) {
        const tag = m[0];
        let j = sql.indexOf(tag, i + tag.length);
        j = j < 0 ? n : j + tag.length;
        buf += sql.slice(i, j); i = j; continue;
      }
    }
    if (c === ";") { out.push(buf + ";"); buf = ""; i++; continue; }
    buf += c; i++;
  }
  if (buf.trim()) out.push(buf);
  return out.filter((s) => s.replace(/--[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/;/g, "").trim() !== "");
}
