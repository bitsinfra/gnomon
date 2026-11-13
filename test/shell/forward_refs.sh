#!/usr/bin/env bash
# The plain-SQL install form checks SQL-language bodies at creation: no forward references.
cd "$(dirname "$0")/../.." && python3 tools/check_forward_refs.py && echo ok
