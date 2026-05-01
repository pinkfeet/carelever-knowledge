# UI Multi-Domain Hosting (assessment-ui)

How to serve the five Angular portals (`internal`, `client`, `candidate`, `affiliate`, `doctor`) from distinct hostnames while keeping a single ECS service and Docker image.

## Current state

`carelever_assessment_ui` builds all five apps into one image and serves them via path-based routing:

- Build: each app compiled with `--base-href /<portal>/` (see [`.circleci/config.yml`](../../carelever_assessment_ui/.circleci/config.yml) lines 34–42 and [`Dockerfile`](../../carelever_assessment_ui/Dockerfile) lines 19–23).
- Runtime: nginx inside the container maps `/<portal>/` to `/usr/share/nginx/html/<portal>/` (see [`docker_config/nginx.conf`](../../carelever_assessment_ui/docker_config/nginx.conf)).
- Deploy: one ECS service per environment (`dev-assessment-ui-service`, `staging-assessment-ui-service`, `prod-assessment-ui-service`).
- Entry: `GET /` redirects to `/internal/login/`.

All portals therefore share a single hostname (e.g. `app.carelever.com/internal/…`, `/client/…`).

## Goal

Map each portal to its own hostname, e.g.:

| Portal    | Prod hostname                | Dev hostname                     |
|-----------|------------------------------|----------------------------------|
| internal  | `internal.carelever.com`     | `internal.dev.carelever.com`     |
| client    | `client.carelever.com`       | `client.dev.carelever.com`       |
| candidate | `candidate.carelever.com`    | `candidate.dev.carelever.com`    |
| affiliate | `affiliate.carelever.com`    | `affiliate.dev.carelever.com`    |
| doctor    | `doctor.carelever.com`       | `doctor.dev.carelever.com`       |

…without splitting the single ECS service into five.

## Options considered

### 1. ALB host-based routing only (rejected)

Angular bundles compiled with `--base-href /internal/` have the prefix baked into generated asset URLs and router paths. Pure host routing at the ALB can't strip that prefix — ALB supports redirects, not path rewrites. Would force per-portal images/services.

### 2. ALB host routing + path rewrite (rejected)

ALB has no native path rewrite. Would require CloudFront in front, or a rewriting sidecar. More moving parts than option 3.

### 3. nginx host-based `server` blocks with `--base-href /` builds (recommended)

One ECS service, one image. Each app builds with the default base-href (`/`), each lands in its own subfolder inside the image, and nginx picks the right subfolder based on the `Host` header.

## Implementation sketch

### CI ([`.circleci/config.yml`](../../carelever_assessment_ui/.circleci/config.yml) lines 34–42)

Drop the `--base-href` flag (root is the default):

```yaml
- run:
    name: Build All Apps
    command: |
      pnpm nx build internal  --configuration=$NG_BUILD_ENV
      pnpm nx build client    --configuration=$NG_BUILD_ENV
      pnpm nx build candidate --configuration=$NG_BUILD_ENV
      pnpm nx build affiliate --configuration=$NG_BUILD_ENV
      pnpm nx build doctor    --configuration=$NG_BUILD_ENV
```

### Dockerfile ([`Dockerfile`](../../carelever_assessment_ui/Dockerfile) lines 19–23)

Same change:

```dockerfile
RUN pnpm nx build internal  --configuration="$NG_BUILD_ENV" && \
    pnpm nx build client    --configuration="$NG_BUILD_ENV" && \
    pnpm nx build candidate --configuration="$NG_BUILD_ENV" && \
    pnpm nx build affiliate --configuration="$NG_BUILD_ENV" && \
    pnpm nx build doctor    --configuration="$NG_BUILD_ENV"
```

The `COPY --from=build-stage ... /usr/share/nginx/html/<portal>/` lines at L62–66 stay as-is — per-portal subfolders on disk are exactly what the new nginx config needs.

### nginx ([`docker_config/nginx.conf`](../../carelever_assessment_ui/docker_config/nginx.conf))

Replace the single `server` block with one `server` block per portal. Each uses `server_name` to match its hostnames and `root` to point into its own subfolder:

```nginx
worker_processes 1;
events { worker_connections 1024; }

http {
  server_tokens off;
  more_clear_headers 'Server';
  include /etc/nginx/mime.types;

  gzip on;
  gzip_min_length 1000;
  gzip_proxied expired no-cache no-store private auth;
  gzip_types text/plain text/css application/json application/javascript
             application/x-javascript text/xml application/xml
             application/xml+rss text/javascript;

  # --- portal: internal ---
  server {
    listen 80;
    server_name internal.carelever.com
                internal.dev.carelever.com
                internal.staging.carelever.com;

    root /usr/share/nginx/html/internal;
    index index.html;

    include /etc/nginx/security-headers.conf;

    location / {
      try_files $uri $uri/ /index.html;
    }
  }

  # --- portal: client ---
  server {
    listen 80;
    server_name client.carelever.com
                client.dev.carelever.com
                client.staging.carelever.com;
    root /usr/share/nginx/html/client;
    index index.html;
    include /etc/nginx/security-headers.conf;
    location / { try_files $uri $uri/ /index.html; }
  }

  # --- candidate, affiliate, doctor: same pattern ---

  # Catch-all for unknown hosts
  server {
    listen 80 default_server;
    server_name _;
    return 404;
  }
}
```

Extract the `add_header` block currently in [`nginx.conf`](../../carelever_assessment_ui/docker_config/nginx.conf) lines 19–23 into `docker_config/security-headers.conf` and `COPY` it into the image alongside `nginx.conf`. Each `server` block then `include`s it — avoids five-way duplication.

### AWS

- **Route53**: A/ALIAS record per hostname → existing ALB.
- **ACM**: cert covering all five hostnames (or wildcard `*.carelever.com` + equivalents per env).
- **ALB**: HTTPS listener with the cert attached; default rule forwards to the existing `assessment-ui` target group. No host-based listener rules needed — nginx handles host matching inside the container.
- **ECS**: no change — one service per environment as today.

## Gotchas to audit before switching

1. **Hardcoded path prefixes.** Any Angular code referencing `/internal/`, `/client/`, etc. in router config, asset URLs, or API endpoints will break once the prefix disappears. Grep all five apps.
2. **Root redirect.** The current `GET / → /internal/login/` redirect in [`nginx.conf`](../../carelever_assessment_ui/docker_config/nginx.conf) lines 50–52 is no longer meaningful — each host's `/` now lands in its own Angular app whose router handles the initial route.
3. **Cross-portal links.** If any portal links to another portal via path (e.g. `href="/client/foo"`), those must become absolute URLs to the other hostname. Typically env-driven config.
4. **Cookie domain / SSO.** If auth cookies were set for the bare host, splitting across subdomains may require scoping cookies to `.carelever.com` so all portals share session.
5. **CSP `connect-src`.** Existing CSP in [`nginx.conf`](../../carelever_assessment_ui/docker_config/nginx.conf) line 19 already allows `*.carelever.com` / env variants, so API calls across the new hosts should be fine. Re-verify per env.
6. **CORS on API.** Rails API CORS allowlist must include the new portal hostnames for each env.

## Why not split into five ECS services?

Possible, but costlier and operationally noisier: five task definitions, five services, five deploy jobs in CI, five sets of scaling rules — with no user-visible benefit when a single nginx can route by host inside one container. Revisit only if a portal's resource profile diverges sharply from the others.
