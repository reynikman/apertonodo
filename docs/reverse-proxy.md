# Reverse Proxy in Front of the Apertonodo Server

The Apertonodo server usually does not run exposed directly, but sits behind a reverse proxy (any nginx-compatible one, possibly behind a CDN). Everything below covers pitfalls already encountered; each item references in parentheses an entry number in [troubleshooting.md](troubleshooting.md).

## What the Proxy Must Do

1. **Rate-limit the API by client IP, but exclude images and ready downloads** (49). Search and Play are expensive, so keeping them rate-limited makes sense. Images (`/v1/photos/…`, `/v1/covers/…`) are static files from disk, and a genre screen requests 20–30 at once. Under a shared rate limit, extra requests get dropped, and the app renders letter placeholders instead of photos. Files at `/v1/downloads/{id}/file` are also excluded from the limit: the phone fetches an album sequentially and resumes interrupted transfers via Range. `POST /v1/downloads`, `/v1/downloads/remove`, and polling `GET /v1/downloads` remain rate-limited. Unmetered images and downloads still require authentication.
2. **Do not cut off long Play responses before 60 seconds** (`server/tests/test_play_budget.py`). The server keeps source search under 50 seconds; a proxy with a lower timeout turns a clean "source was not found" into a network error.
3. **Do not write an access-log for this host.** The query string contains search text, which must not be recorded anywhere (see «Где смотреть логи» in `AGENTS.md`).
4. **Pass through the DELETE method** (45). Some proxies do not pass it through (405), and then device revocation over the public endpoint does not work; playlist endpoints intentionally use only GET and POST.

## Nginx Example

The client IP behind a CDN is usually in the `CF-Connecting-IP` header; without a CDN, replace `$http_cf_connecting_ip` with `$binary_remote_addr`. An empty key is ignored by nginx rate limiting — that is how images and ready downloads are excluded.

In the `http` block:

```nginx
map $request_uri $flowtune_limit_key {
    ~^/v1/(photos|covers)/  "";
    ~^/v1/downloads/[0-9a-fA-F-]+/file(?:\?|$)  "";
    default                 $http_cf_connecting_ip;
}
limit_req_zone  $flowtune_limit_key zone=flowtune_api_per_ip:10m rate=2r/s;
limit_conn_zone $flowtune_limit_key zone=flowtune_api_conn_per_ip:10m;
```

In the `server` block of the Apertonodo host:

```nginx
limit_req  zone=flowtune_api_per_ip burst=20 nodelay;
limit_conn flowtune_api_conn_per_ip 10;
access_log off;
proxy_read_timeout 60s;
```

Gotcha when editing live nginx: an existing zone cannot change its key via config reload — `nginx -s reload` fails with "uses the … key while previously it used …". Define a zone with a new name.

## Applying the Limits

If your proxy keeps its host settings in a database or a UI, check that saving the host there does not wipe hand-written `limit_req` / `limit_conn` directives; re-add them after such a save.

Verification after any edit: 30 photos at once via the public address — all 200; 30 requests to `/v1/health` at once — 20 succeed, 10 throttled (API limit is active). No standalone script yet.
