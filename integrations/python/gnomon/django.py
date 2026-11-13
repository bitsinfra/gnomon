"""Django integration.

Add ``"gnomon.django.BranchMiddleware"`` to MIDDLEWARE. A request with an ``X-Gnomon-Branch``
header (or a ``request.gnomon_branch`` attribute set by an earlier middleware) runs on that branch.

* Default: the request's connection is put on the branch with gnomon.use() before the view and
  reset to main afterwards, so a persistent connection never carries the branch to the next request.
* ``GNOMON_TRANSACTION_POOLING = True`` (behind pgbouncer in transaction mode): every transaction
  of the request starts with gnomon.begin(), which lasts exactly one transaction. This needs
  ``ATOMIC_REQUESTS = True`` so the request's queries share a transaction.

``GNOMON_BRANCH_HEADER`` changes the header name.
"""
from __future__ import annotations

import contextvars

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import connections

_current = contextvars.ContextVar("gnomon_branch", default=None)


def current_branch():
    """The branch of the request being served, or None."""
    return _current.get()


class _BeginEachTransaction:
    def __init__(self, conn, branch):
        self.conn, self.branch, self.done = conn, branch, set()

    def __call__(self, execute, sql, params, many, context):
        if not self.conn.in_atomic_block:
            raise ImproperlyConfigured("GNOMON_TRANSACTION_POOLING needs ATOMIC_REQUESTS = True")
        key = id(self.conn.atomic_blocks[0])
        if key not in self.done:
            self.done.add(key)
            context["cursor"].execute("select gnomon.begin(%s)", [self.branch])
        return execute(sql, params, many, context)


class BranchMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        name = getattr(settings, "GNOMON_BRANCH_HEADER", "X-Gnomon-Branch")
        self.header = "HTTP_" + name.upper().replace("-", "_")

    def __call__(self, request):
        b = getattr(request, "gnomon_branch", None) or request.META.get(self.header)
        if not b or b == "main":
            return self.get_response(request)
        conn = connections["default"]
        token = _current.set(b)
        try:
            if getattr(settings, "GNOMON_TRANSACTION_POOLING", False):
                with conn.execute_wrapper(_BeginEachTransaction(conn, b)):
                    return self.get_response(request)
            with conn.cursor() as cur:
                cur.execute("select gnomon.use(%s)", [b])
            try:
                return self.get_response(request)
            finally:
                with conn.cursor() as cur:
                    cur.execute("select gnomon.use('main')")
        finally:
            _current.reset(token)
