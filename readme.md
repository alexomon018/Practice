# Docker & Microservices Practice Project

A four-service stack built to teach Docker Compose, container networking, environment
variable management, logging, and image publishing.

```
        HOST                          │              DOCKER
                                      │
  browser ──> localhost:8080 ─────────┼──> ┌─────────┐
                                      │    │  nginx  │  edge proxy
       (the ONE published port)       │    └────┬────┘
                                      │         │
                                      │    ┌────┴──────────────┐
                                      │  / │               /api│
                                      │    ▼                   ▼
                                      │ ┌──────────┐   ┌───────────┐
                         edge network │ │ frontend │   │  backend  │
                                      │ └──────────┘   └─────┬─────┘
                                      │                      │
                                      │ ════════════════════ │ ═══════
                                      │  data network        │
                                      │  (internal: true)    ▼
                                      │                ┌──────────┐
                                      │                │    db    │──▶ practice_pgdata
                                      │                └──────────┘
```

**Stack:** React 18 + TanStack Query · Node 22 + Express · PostgreSQL 17 · NGINX 1.27

---

## Quick start

```bash
cp .env.example .env          # then edit DOCKERHUB_USER and POSTGRES_PASSWORD
docker compose up -d --build
open http://localhost:8080
```

Development mode (source bind-mounted, Postgres published on loopback, debug logs):

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up
```

Teardown:

```bash
docker compose down       # containers + networks. DATA SURVIVES.
docker compose down -v    # ...and destroys the volume. Data gone.
```

---

## Project layout

```
.
├── .env                   # real values — GITIGNORED
├── .env.example           # template — committed, documents which vars exist
├── docker-compose.yml     # the stack
├── docker-compose.dev.yml # opt-in dev overlay
│
├── backend/               # Express REST API
│   ├── Dockerfile         # multi-stage: deps → runtime
│   ├── .dockerignore
│   └── src/{server,routes,db,logger}.js
│
├── frontend/              # React + TanStack Query
│   ├── Dockerfile         # multi-stage: node build → nginx runtime
│   ├── .dockerignore
│   ├── nginx.conf         # static-file server (no proxying)
│   ├── docker-entrypoint.d/10-runtime-config.sh   # env → config.js at startup
│   ├── public/config.js   # dev defaults, overwritten in the container
│   └── src/{main,App}.jsx, api.js, style.css
│
├── nginx/conf.d/          # EDGE proxy config (bind-mounted, hot-reloadable)
│   ├── 00-upgrade-map.conf
│   └── default.conf
│
└── db/init/               # run ONCE, on first start, alphabetically
    ├── 01_schema.sql
    └── 02_seed.sql
```

---

## 1. Networking

### Internal DNS

Every container on a **user-defined** network gets `nameserver 127.0.0.11` injected
into `/etc/resolv.conf`. That address is a DNS server the Docker daemon runs; it
resolves **service names** to current container IPs.

```bash
docker compose exec backend cat /etc/resolv.conf     # nameserver 127.0.0.11
docker compose exec backend nslookup db              # → 192.168.107.2
docker compose exec nginx   nslookup db              # → NXDOMAIN
```

nginx gets **NXDOMAIN**, not "connection refused". The embedded DNS scopes answers to
the networks the *asking* container belongs to — isolation is enforced at name
resolution, before a packet is ever sent.

> The legacy default `bridge` network has **no** embedded DNS. That is why old
> tutorials use the deprecated `--link` flag. Compose always creates user-defined
> networks, so you get DNS for free.

### Why two networks

| Network | `internal` | Members | Purpose |
|---|---|---|---|
| `practice-edge` | false | nginx, frontend, backend | public-facing tier |
| `practice-data` | **true** | backend, db | database tier |

`internal: true` removes the gateway: containers on it have **no outbound internet
access** and cannot be published to the host. The backend is the only dual-homed
container — it has two IPs, one per network:

```bash
docker compose exec backend ip -o -4 addr show
# eth0 192.168.107.3/24   (data)
# eth1 192.168.97.2/24    (edge)
```

### Exposed vs published ports

```
ports:  "8080:80"   → HOST:CONTAINER. Creates a NAT rule. Reachable from your LAN.
expose: "3000"      → documentation ONLY. Publishes nothing.
```

Containers sharing a network can reach **any** port on each other regardless of either
keyword. So the real question is *"what should my laptop and LAN reach?"*

| Service | Host-reachable? | Why |
|---|---|---|
| nginx | ✅ `:8080` | the single entry point |
| frontend | ❌ | reached via nginx |
| backend | ❌ | reached via nginx |
| db | ❌ | reached only by backend, on an internal network |

```bash
curl localhost:8080/api/health   # ✅ 200
curl localhost:3000/api/health   # ❌ connection refused — never published
```

⚠️ **On Linux, publishing a port bypasses UFW/firewalld.** Docker writes directly to
the `DOCKER` iptables chain, ahead of your rules. `ports: "5432:5432"` on a laptop
exposes your database to the whole coffee-shop wifi. Bind to loopback instead:
`"127.0.0.1:5432:5432"`.

### Never use `localhost` between containers

Each container has its own network namespace and its own loopback. Inside the backend,
`localhost` **is** the backend. Use service names:

```yaml
POSTGRES_HOST: db          # ✅ resolved by Docker DNS
POSTGRES_HOST: localhost   # ❌ the backend talking to itself
```

Same rule for binding: `app.listen(PORT, '0.0.0.0')`. A server bound to `127.0.0.1`
inside a container is unreachable from anywhere else — the #1 cause of "nginx can't
reach my backend".

### The nginx resolver trap

```nginx
proxy_pass http://backend:3000;          # ❌ resolved ONCE at config load
```

nginx caches that IP forever. Recreate the backend, it gets a new address, and nginx
proxies to a corpse — permanent 502 until you restart nginx. It also **refuses to
start** if the name doesn't resolve at boot.

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;  # ✅ Docker's DNS
set $backend_upstream http://backend:3000;
proxy_pass $backend_upstream$request_uri;
```

A **variable** in `proxy_pass` forces per-request resolution. The trade-off: variable
form does no automatic URI rewriting, so `$request_uri` must be appended manually.

---

## 2. Environment variables

Two mechanisms that look alike and are not:

| | Where it acts | Example |
|---|---|---|
| `${FOO}` in compose | on the host, by the Compose CLI, **before containers exist** | `ports: "${NGINX_HOST_PORT}:80"` |
| `environment:` / `env_file:` | inside the container's process | `POSTGRES_HOST: db` |

A variable in `.env` does **not** automatically appear inside a container. It only
becomes available for `${...}` substitution in the YAML.

### Keeping secrets out of the code

- `.env.example` is **committed** — it documents *which* variables exist.
- `.env` is **gitignored** — it holds *what* they contain.
- `.env` is in both `.dockerignore` files, so `COPY . .` can never bake it into a
  layer. (Layers are immutable: a secret copied in step 3 stays in the image history
  even if step 8 deletes the file.)

Verify the image is config-free:

```bash
docker run --rm amiticvega/practice-backend:0.1.0 printenv | grep -i postgres
#  → nothing. All DB config arrives at runtime.
```

> For production, `.env` files are the *floor*, not the ceiling. Graduate to Docker
> Swarm secrets (`/run/secrets/...`), Kubernetes Secrets, or a vault — env vars are
> visible in `docker inspect` and leak into crash dumps and child processes.

### Frontend env vars are a different problem

A browser has no `process.env`. Vite substitutes `import.meta.env.VITE_*` at **build**
time, baking values into the bundle — which forces one image per environment and
breaks "build once, promote the same artifact".

This project ships an env-agnostic bundle and renders config at **container start**:

```
frontend/docker-entrypoint.d/10-runtime-config.sh
   ↓  reads $API_BASE_URL, $APP_TITLE
   ↓  writes /usr/share/nginx/html/config.js
window.__APP_CONFIG__ = { apiBaseUrl: "/api", ... }
```

nginx serves `/config.js` with `Cache-Control: no-store` so a browser can never pin a
stale environment. Change a value → `docker compose up -d frontend` → no rebuild.

```bash
docker compose exec frontend cat /usr/share/nginx/html/config.js
```

⚠️ **Never put a secret in a frontend container.** Anything reaching the browser is
public by definition.

---

## 3. Logging

**Rule: containers log to stdout/stderr. Never to files.**

Docker attaches to the process's file descriptors and hands them to a *logging driver*.
A log file inside a container is invisible to `docker logs`, grows until the disk dies,
has no rotation, and vanishes with the container.

| Service | How |
|---|---|
| backend | `process.stdout.write(JSON.stringify(entry))`; warn/error → stderr |
| nginx | `access_log /dev/stdout json_combined; error_log /dev/stderr` |
| postgres | logs to stdout by default |

### Inspecting

```bash
docker compose logs                    # everything, prefixed by service
docker compose logs -f backend         # follow one service
docker compose logs --tail 50 nginx    # last 50 lines
docker compose logs --since 10m        # time-filtered
docker compose logs --no-log-prefix backend | jq .   # clean JSON for jq

docker logs practice-backend           # same, by CONTAINER name
docker logs --details practice-backend
```

`docker compose logs <service>` uses service names; `docker logs <container>` uses
container names. Compose can merge several containers per service; `docker logs` cannot.

### Tracing one request across services

nginx generates `$request_id` and forwards it as `X-Request-Id`; the backend logs the
same value:

```bash
docker compose logs --no-log-prefix | grep 33e4c356563730b079d42148821ab844
```
```json
{"service":"nginx-edge","request_id":"33e4c356…","path":"/api/items","status":201,"upstream":"192.168.97.2:3000","upstream_time":"0.023"}
{"service":"backend","requestId":"33e4c356…","method":"POST","status":201,"durationMs":11.76}
```

Comparing `upstream_time` (nginx's view) with `durationMs` (the app's view) tells you
whether latency is in the app or the network.

### Log rotation — the most forgotten production setting

The default `json-file` driver has **no size limit**.

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"     # → 30MB ceiling per container
```

### Common mistake: duplicate log lines

We hit this live. The base nginx image declares `access_log … main;` in the `http`
context. Adding ours at the *same* level meant **both** were active — every request
logged twice.

nginx does not merge log directives; it **overrides at the most specific level**. The
fix was moving `access_log` into `server { }`.

---

## 4. PostgreSQL initialisation

On the very first start, when `/var/lib/postgresql/data` is empty:

```
1. initdb                          → cluster + SUPERUSER role $POSTGRES_USER
2. start a TEMPORARY server        → UNIX SOCKET ONLY, no TCP
3. CREATE DATABASE "$POSTGRES_DB"
4. run /docker-entrypoint-initdb.d/*   ← 01_schema.sql, then 02_seed.sql
5. stop temp server, start for real → NOW listening on TCP :5432
```

Consequences:

- **Do not write `CREATE DATABASE` / `CREATE USER` in your init scripts.** Steps 1 and
  3 already did it from `POSTGRES_DB` / `POSTGRES_USER`. Your scripts run *as* that
  user, already connected to that database.
- **Alphabetical order is the only ordering guarantee** — hence `01_`, `02_`.
- Step 2 uses a socket only, so a half-initialised database is never reachable over the
  network. This is why our healthcheck is `pg_isready -h 127.0.0.1` — without `-h` it
  would use the socket and report ready *during* initialisation.

### Init scripts run ONCE, ever

Edit `01_schema.sql` after the first `up` and **nothing happens** — the volume already
has data:

```
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

To force a re-init: `docker compose down -v` (destroys the volume).

This is why init scripts are a **seeding** tool, not a **migration** tool. Real schema
changes belong in a migration runner the app executes at boot.

### Least privilege (not done here)

`POSTGRES_USER` is a **superuser**. For production you'd add a restricted role in
`01_schema.sql` and point the app at it, keeping the superuser for migrations only:

```sql
CREATE ROLE app_rw LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE practicedb TO app_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;
```

---

## 5. Volumes

A container's writable layer is **deleted when the container is removed** — which
includes every image update and every `docker compose down`.

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data           # named volume → survives
  - ./db/init:/docker-entrypoint-initdb.d:ro  # bind mount   → your files
```

| | Named volume | Bind mount |
|---|---|---|
| Source | Docker-managed | a path you choose |
| Syntax | a *name* (`pgdata`) | a *path* (`./db/init`) |
| Deleted by `down -v` | **yes** | no |
| Best for | data the container writes | config/source you edit |

Bind mounts are not copies — same inode, different namespace. Edit on the host, the
container sees it instantly. That is what `docker-compose.dev.yml` exploits for
live-reload.

Postgres data belongs in a **named** volume: on macOS/Windows a bind mount crosses a VM
filesystem boundary — much slower, with a history of fsync bugs.

### The anonymous-volume trap (we hit this for real)

The postgres image declares `VOLUME /var/lib/postgresql/data` in its own Dockerfile.
That is **mandatory** — Docker must mount *something* there. Omit the named volume and
you get an **anonymous** one: a fresh, empty volume per container.

The failure mode is maximally deceptive:

- works perfectly while running ✅
- survives `docker compose restart` ✅
- **loses everything on `down` + `up`** ❌
- leaks a 400MB orphan volume per cycle, named with a hex string, which no
  `docker compose down -v` will ever clean up

Diagnostic:

```bash
docker inspect practice-db -f '{{json .Mounts}}' | jq
# hex-string volume name where you expected practice_pgdata → anonymous volume
docker volume ls -f dangling=true
```

Verify persistence properly:

```bash
curl -X POST localhost:8080/api/items -H 'Content-Type: application/json' \
     -d '{"name":"Survives Restart"}'
docker compose down && docker compose up -d && sleep 20
curl -s localhost:8080/api/items | grep "Survives Restart"   # must still be there
```

---

## 6. Images & Dockerfiles

### Layer caching drives instruction order

Every instruction is a cached layer; cache invalidates at the **first** changed
instruction and everything below rebuilds. So manifests are copied before source:

```dockerfile
COPY package.json package-lock.json ./
RUN npm ci                  # ← stays cached when only src/ changes
COPY src ./src
```

`npm ci`, never `npm install`: `ci` requires a lockfile, installs it exactly, and wipes
`node_modules` first. `install` can silently resolve newer versions — meaning your
image differs from what you tested.

### Multi-stage

| | backend | frontend |
|---|---|---|
| Stage 1 | `npm ci --omit=dev` | `npm ci` (needs vite) + `npm run build` |
| Stage 2 | `node:22-alpine` + prod deps | `nginx:1.27-alpine` + `dist/` only |
| Ships | no dev deps, no npm cache | **zero Node in production** |
| Size | 233 MB | **78 MB** |

Only `COPY --from=build` crosses the boundary. Source, `node_modules` and the npm cache
stay in the discarded stage — not in the image, not in its history.

Smaller isn't only about disk: fewer packages means fewer CVEs to patch, and no
`npm`/`node` binary for an attacker to pivot with.

### Other decisions

```dockerfile
ARG NODE_VERSION=22-alpine    # pin a major; `latest` makes builds unreproducible
USER node                     # non-root: containers are not a security boundary
EXPOSE 3000                   # documentation only — publishes nothing
HEALTHCHECK ...               # image is self-describing even outside Compose
CMD ["node", "src/server.js"] # EXEC form — see below
```

**Exec form is not cosmetic.** `CMD node src/server.js` runs as
`/bin/sh -c "node src/server.js"`; **sh** becomes PID 1 and does not forward SIGTERM.
`docker stop` then always waits the full 10s timeout and SIGKILLs — graceful shutdown
never runs, in-flight requests die. The JSON array form makes node PID 1.

Related: the main process must stay in the **foreground**. That's why the nginx image
runs `nginx -g 'daemon off;'` — if it daemonised, PID 1 would exit and Docker would
consider the container finished.

### `.dockerignore`

Excludes files from the **build context** (the tarball shipped to the daemon before the
build starts). Three reasons it matters:

1. **Speed** — don't upload 300MB of `node_modules` on every build.
2. **Cache** — `COPY . .` hashes the context; a stray `.log` busts every layer below.
3. **Secrets** — `COPY . .` with a local `.env` bakes credentials into a layer forever.

Also: host `node_modules` may contain wrong-platform native binaries (macOS arm64 vs
linux amd64), producing errors like `Cannot find module @rollup/rollup-linux-x64-gnu`.

---

## 7. Health checks & startup order

```yaml
depends_on:
  db:
    condition: service_healthy
```

- `depends_on: [db]` alone orders **container start** only. Postgres needs seconds to
  become ready, so the backend can still start against a database refusing connections.
- `condition: service_healthy` waits for the healthcheck to pass. Much better.
- **Still not enough.** It says nothing about the DB restarting later, and other
  orchestrators have no equivalent. The app retries on boot too
  ([backend/src/db.js](backend/src/db.js)) — belt *and* braces.

The two together form a **two-level backoff**: the app retries fast (seconds) for
transient blips; if it exhausts them it exits non-zero and Docker's
`restart: unless-stopped` takes over with its own escalating delay.

### Liveness vs readiness

| Endpoint | Question | Checks DB? | On failure |
|---|---|---|---|
| `/api/health` | am I alive? | no | restart me |
| `/api/ready` | can I serve? | yes | stop routing to me — **don't** restart |

Conflating them causes a classic outage: the DB hiccups → every replica fails liveness →
all restart simultaneously → the DB now also gets a connection storm from the restarts.

---

## 8. Debugging containers

```bash
# What is running, and what is published?
docker compose ps
docker compose ps --format json | jq

# Shell inside a container (exec = running container; run = new one)
docker compose exec backend sh
docker compose exec db psql -U appuser -d practicedb

# Environment actually seen by the process
docker compose exec backend printenv | sort

# Networking
docker compose exec backend cat /etc/resolv.conf
docker compose exec backend nslookup db
docker compose exec backend ip -o -4 addr show
docker network ls
docker network inspect practice-edge

# Mounts (catches the anonymous-volume trap)
docker inspect practice-db -f '{{json .Mounts}}' | jq

# Why did it die?
docker inspect practice-backend -f '{{.State.ExitCode}} {{.State.Error}}'
docker inspect practice-backend -f '{{json .State.Health}}' | jq

# Live resource usage
docker stats --no-stream

# nginx: validate BEFORE reloading, then reload with zero downtime
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload

# Image forensics — how did this layer get so big?
docker history amiticvega/practice-backend:0.1.0
```

**Container exits immediately and `exec` fails?** `exec` needs a *running* container.
Use `docker compose logs <service>` to see why it died, or start a throwaway container
with a different entrypoint:

```bash
docker run --rm -it --entrypoint sh amiticvega/practice-backend:0.1.0
```

### Failure drills worth running

```bash
# 1. Kill the API — frontend must keep serving, /api returns our JSON 502
docker compose stop backend
curl -i localhost:8080/api/items
curl -o /dev/null -w '%{http_code}\n' localhost:8080/

# 2. Recover without touching nginx (proves runtime DNS resolution)
docker compose up -d backend
curl -s localhost:8080/api/items | head -c 80

# 3. Prove network isolation
docker compose exec nginx nc -z -w 3 db 5432   # must fail: no route
```

---

## 9. Publishing to Docker Hub

Images are already named for the registry, which is what makes `push` work:

```yaml
image: ${DOCKERHUB_USER}/practice-backend:${IMAGE_TAG}
```

A Docker Hub reference is `[registry/]namespace/repository:tag`. Omitting the registry
defaults to `docker.io`.

### 1 — Create private repositories

On hub.docker.com → **Create Repository** → `practice-backend`, visibility **Private**.
Repeat for `practice-frontend`. (Docker Hub creates repos on push, but they default to
**public** — create them explicitly to guarantee private.)

### 2 — Log in

```bash
docker login -u amiticvega
```

Use a **Personal Access Token** (Account Settings → Security), not your password: it's
scopeable and revocable. On macOS the credential goes into Keychain via
`docker-credential-osxkeychain`; check with `cat ~/.docker/config.json`.

### 3 — Tag

```bash
# Compose already built them with the right names:
docker images | grep amiticvega

# Add a moving 'latest' alongside the immutable version tag.
docker tag amiticvega/practice-backend:0.1.0  amiticvega/practice-backend:latest
docker tag amiticvega/practice-frontend:0.1.0 amiticvega/practice-frontend:latest
```

`docker tag` does **not** copy anything — it adds another name pointing at the same
image ID.

> Deploy by **immutable version tag**, never `latest`. `latest` is just a default tag
> string with no special meaning; two machines pulling `latest` a week apart can run
> different code, and rollback becomes guesswork.

### 4 — Push

```bash
docker compose push                              # both services at once
# or individually:
docker push amiticvega/practice-backend:0.1.0
docker push amiticvega/practice-frontend:0.1.0
docker push amiticvega/practice-backend:latest
docker push amiticvega/practice-frontend:latest
```

Layers already present in the registry are skipped (`Layer already exists`) — that's
content-addressable storage, and another payoff of good layer ordering.

### 5 — Verify from a clean state

```bash
docker logout
docker image rm amiticvega/practice-backend:0.1.0
docker pull amiticvega/practice-backend:0.1.0    # must FAIL → repo is private ✅
docker login -u amiticvega
docker pull amiticvega/practice-backend:0.1.0    # succeeds
```

Pulling on a server needs credentials too: `docker login` there, or a registry secret in
your orchestrator.

### Multi-architecture

An image built on an Apple Silicon Mac is `linux/arm64` and **will not run** on an
amd64 server. Build a manifest list for both:

```bash
docker buildx create --use --name practice-builder
docker buildx build --platform linux/amd64,linux/arm64 \
  -t amiticvega/practice-backend:0.1.0 --push ./backend
```

`buildx --push` uploads directly; it does not leave a local image behind.

---

## 10. Common mistakes checklist

| ❌ Mistake | ✅ Correct | Symptom |
|---|---|---|
| `app.listen(PORT, '127.0.0.1')` | `'0.0.0.0'` | nginx gets connection refused |
| `POSTGRES_HOST=localhost` | `POSTGRES_HOST=db` | ECONNREFUSED from the backend |
| `proxy_pass http://backend:3000;` | `resolver` + variable | permanent 502 after recreate |
| No named volume on the DB | `- pgdata:/var/lib/postgresql/data` | data lost on `down`, orphan volumes |
| `CMD node server.js` | `CMD ["node","server.js"]` | `docker stop` takes 10s, no graceful shutdown |
| `npm install` in Dockerfile | `npm ci` | image ≠ what you tested |
| `COPY . .` without `.dockerignore` | add one | secrets baked into layers |
| Logging to a file | stdout/stderr | `docker logs` empty, disk fills |
| No `max-size` on the driver | `max-size: 10m` | host disk fills silently |
| `image: postgres:latest` | pin the major | surprise major upgrade breaks the data dir |
| Running as root | `USER node` | uid 0 on the host kernel after an escape |
| `ports: "5432:5432"` | `"127.0.0.1:5432:5432"` or none | DB exposed to the LAN, bypassing UFW |
| `CREATE DATABASE` in init SQL | use `POSTGRES_DB` | "database already exists" |
| Editing init SQL after first run | `down -v` to re-init | changes silently ignored |
| `access_log` at `http` level | put it in `server{}` | every request logged twice |
| Same probe for liveness & readiness | separate them | DB blip → restart storm |
| `VITE_API_URL` at build time | runtime `config.js` | one image per environment |
| Deploying `:latest` | immutable version tags | cannot reproduce or roll back |

---

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | React app (proxied to `frontend:80`) |
| GET | `/healthz` | edge proxy liveness |
| GET | `/api/health` | backend liveness (no dependencies) |
| GET | `/api/ready` | backend readiness (pings the DB) |
| GET | `/api/info` | non-secret config + `servedBy` container ID |
| GET | `/api/items` | list items |
| POST | `/api/items` | create item |
| DELETE | `/api/items/:id` | delete item |
