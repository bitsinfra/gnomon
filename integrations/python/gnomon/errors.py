"""Typed errors (sdk/spec/SPEC.md, Errors). The SQLSTATE stays the standard one; the slug in the
hint (``[gnomon:<slug>]``) is gnomon's stable code."""
from __future__ import annotations

import re
from typing import Any, Optional

_SLUG = re.compile(r"\[gnomon:([a-z_]+)\]")


class GnomonError(Exception):
    def __init__(self, message: str, *, code: Optional[str] = None, sqlstate: Optional[str] = None,
                 hint: Optional[str] = None, cause: Optional[BaseException] = None):
        super().__init__(message)
        self.code, self.sqlstate, self.hint, self.cause = code, sqlstate, hint, cause


class SerializationError(GnomonError): ...
class PermissionError(GnomonError): ...  # noqa: A001 (gnomon's, not the builtin)
class BranchClosedError(GnomonError): ...
class StatementTimeoutError(GnomonError): ...
class UnsupportedOnBranchError(GnomonError): ...
class NotRoutedError(GnomonError): ...
class OverQuotaError(GnomonError): ...
class IncompatibleVersionError(GnomonError): ...


class ChecksFailedError(GnomonError):
    results: Any = None


class MergeConflictError(GnomonError):
    def __init__(self, message: str, merge_id: int, conflicts: list):
        super().__init__(message, code="merge_conflict")
        self.merge_id, self.conflicts = merge_id, conflicts


def to_gnomon_error(err: BaseException) -> GnomonError:
    """Map a psycopg error to a typed gnomon error."""
    if isinstance(err, GnomonError):
        return err
    sqlstate = getattr(err, "sqlstate", None)
    diag = getattr(err, "diag", None)
    hint = getattr(diag, "message_hint", None) if diag is not None else None
    msg = getattr(diag, "message_primary", None) or str(err)
    m = _SLUG.search(f"{hint or ''} {msg}")
    slug = m.group(1) if m else None
    kw = dict(code=slug, sqlstate=sqlstate, hint=hint, cause=err)
    if sqlstate == "40001":
        return SerializationError(msg, **kw)
    if sqlstate == "57014":
        return StatementTimeoutError(msg, **kw)
    if sqlstate == "42P10" or slug in ("sql_only_dml", "upsert_on_branch"):
        return UnsupportedOnBranchError(msg + " (on a branch, write an upsert as UPDATE then INSERT ... WHERE NOT EXISTS, or load gnomon's C module)", **kw)
    if slug == "not_routed":
        return NotRoutedError(msg, **kw)
    if sqlstate == "25006" or slug == "branch_closed":
        return BranchClosedError(msg, **kw)
    if sqlstate == "53400" or slug == "over_quota":
        return OverQuotaError(msg, **kw)
    if sqlstate == "23514":
        return ChecksFailedError(msg, **kw)
    if sqlstate == "42501":
        return PermissionError(msg, **kw)
    return GnomonError(msg, **kw)
