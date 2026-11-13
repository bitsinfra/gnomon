"""Give every `raise exception` in src/sql a stable slug in its hint:
[gnomon:<slug>], derived from the message. Idempotent; prints what it could not place."""
import glob, re, sys

STOP = {"the", "a", "an", "is", "are", "of", "to", "on", "in", "for", "it", "this", "and", "or", "by", "be", "with",
        "that", "as", "at", "from", "has", "have", "its", "was", "were", "any", "one", "only", "so", "use", "gnomon"}
RX = re.compile(r"raise exception\s+'((?:[^']|'')*)'(.*?);", re.S)


def slug(msg: str) -> str:
    m = re.sub(r"%|\"[^\"]*\"|\([^)]*\)", " ", msg.replace("''", "'")).lower()
    words = [w for w in re.findall(r"[a-z][a-z0-9_]*", m) if w not in STOP]
    return "_".join(words[:4])[:40].strip("_") or "error"


def fix(match):
    body, msg, rest = match.group(0), match.group(1), match.group(2)
    if "[gnomon:" in body or msg.startswith("FAILED"):
        return body
    tag = f"[gnomon:{slug(msg)}]"
    head = body[: len(body) - len(rest) - 1]  # up to the message literal's end
    if re.search(r"\busing\b", rest, re.I):
        h = re.search(r"\bhint\s*=\s*'((?:[^']|'')*)'", rest, re.I)
        if h:
            lit = h.group(0)
            return head + rest.replace(lit, lit[:-1] + " " + tag + "'", 1) + ";"
        if re.search(r"\bhint\s*=", rest, re.I):
            missed.append(msg[:60])
            return body
        return head + rest + f", hint = '{tag}';"
    return head + rest + f" using hint = '{tag}';"


missed = []
n = 0
for f in sorted(glob.glob("src/sql/*.sql")):
    s = open(f).read()
    t = RX.sub(fix, s)
    if t != s:
        n += sum(1 for _ in RX.finditer(t)) - sum(1 for m in RX.finditer(s) if "[gnomon:" in m.group(0))
        open(f, "w").write(t)
print("hints with a format() expression, left as they are:", len(missed))
for m in missed:
    print("  ", m)
