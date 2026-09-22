"""Deployment-only edge gate — keeps CloudFront concerns out of the demo app.

When the box is fronted by CloudFront (see provision_cloudfront.py), the deployed process serves
THIS wrapper (uvicorn edge_gate:app) instead of server:app. It rejects any request lacking the
secret X-Origin-Verify header CloudFront stamps on every origin request, so hitting :8080 directly
(e.g. from a corp-CIDR peer that the instance SG still admits) is refused. Local dev serves
server:app directly and is unaffected. run.sh sources deploy/.env so the secret is in the env below.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # demo/ -> import server
from server import app as _app

_SECRET = os.environ.get("ORIGIN_SHARED_SECRET", "")


async def app(scope, receive, send):
    if scope["type"] == "http" and _SECRET:
        headers = dict(scope.get("headers") or [])
        if headers.get(b"x-origin-verify", b"").decode() != _SECRET:
            await send({"type": "http.response.start", "status": 403,
                        "headers": [(b"content-length", b"0")]})
            await send({"type": "http.response.body", "body": b""})
            return
    await _app(scope, receive, send)
