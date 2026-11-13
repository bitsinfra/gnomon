#!/usr/bin/env python3
"""SQL-language functions are checked when created in the plain-SQL install form (it runs with
check_function_bodies on), so one that calls a gnomon function defined later in src/sql breaks
that form. List them; exit 1 if there are any. (PL/pgSQL bodies are checked at first call.)"""
import glob
import re
import sys

src = ''.join(open(f).read() for f in sorted(glob.glob('src/sql/*.sql')))
defs = {}
for m in re.finditer(r'create (?:or replace )?(?:function|procedure) ((?:gnomon|_gnomon)\.[a-z_0-9]+)\s*\(', src):
    defs.setdefault(m.group(1), m.start())
bad = set()
for m in re.finditer(r'create (?:or replace )?function ((?:gnomon|_gnomon)\.[a-z_0-9]+)\s*\((.*?)\$(\w*)\$(.*?)\$\3\$', src, re.S):
    name, header, _, body = m.groups()
    if not re.search(r'language\s+sql\b', header, re.I):
        continue
    for r in set(re.findall(r'((?:gnomon|_gnomon)\.[a-z_0-9]+)\s*\(', body)):
        if r in defs and defs[r] > m.start() and r != name:
            bad.add((name, r))
for name, r in sorted(bad):
    print(f'{name} (language sql) calls {r}, defined later: make it plpgsql or move {r} up')
sys.exit(1 if bad else 0)
