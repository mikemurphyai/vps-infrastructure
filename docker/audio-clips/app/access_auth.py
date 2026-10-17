"""Cloudflare Access verification, shared by the UI and Traefik forward-auth service."""
import os
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt


@lru_cache(maxsize=4)
def jwks_client(domain):
    return jwt.PyJWKClient(f"{domain}/cdn-cgi/access/certs", timeout=5, lifespan=300)


def validate_access_token(token, *, domain=None, audience=None, signing_key=None):
    domain = (domain or os.environ.get("CF_ACCESS_TEAM_DOMAIN", "")).rstrip("/")
    audience = audience or os.environ.get("CF_ACCESS_AUD", "")
    if not domain.startswith("https://") or not audience:
        raise ValueError("Cloudflare Access configuration is required.")
    if not token or len(token) > 16384:
        raise ValueError("A valid Cloudflare Access session is required.")
    key = signing_key or jwks_client(domain).get_signing_key_from_jwt(token).key
    claims = jwt.decode(token, key, algorithms=["RS256"], audience=audience, issuer=domain,
                        options={"require":["exp","iat","aud","iss","sub","email"]})
    email = claims["email"]
    if not isinstance(email,str) or "@" not in email or len(email)>320:
        raise ValueError("A verified email identity is required.")
    return email.strip().lower()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Never log request headers or bearer tokens.

    def do_GET(self):
        status = 200
        if self.path != "/health":
            try:
                validate_access_token(self.headers.get("Cf-Access-Jwt-Assertion", ""))
            except Exception:
                status = 403
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b"ok" if status == 200 else b"Sign in through Cloudflare Access.")


if __name__ == "__main__":
    if not os.environ.get("CF_ACCESS_AUD") or not os.environ.get("CF_ACCESS_TEAM_DOMAIN"):
        raise SystemExit("Cloudflare Access settings are required.")
    ThreadingHTTPServer(("0.0.0.0", 8518), Handler).serve_forever()
