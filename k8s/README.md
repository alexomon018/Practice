# Practice on Kubernetes

The compose stack, lifted onto a local `kind` cluster. Every command runs from the **repository root**.

## Bring it up

**Two things here are genuinely order-dependent: the cluster, and the
CloudNativePG operator.** There is no API server to send declarations to until
the cluster exists — you cannot declaratively create the thing that accepts
declarations. And `postgres-cluster.yaml` is `kind: Cluster`, a *custom*
resource: the API server does not know that word until the operator's CRDs are
registered, so applying it early is a hard `no matches for kind "Cluster"`
error rather than an object that waits around.

Unlike the Gateway API path, `Ingress` is a **core** API kind
(`networking.k8s.io/v1`), built into every cluster from the moment the API
server starts. There is no CRD registration step and nothing to admission-
reject: you can `kubectl apply -k k8s/base` before the ingress-nginx
controller even exists. The `Ingress` object is simply accepted and sits
unfulfilled — no controller is watching it yet — until step 2's controller
shows up and starts reconciling it. That is also why step 2 doesn't need
`--server-side`: there's no giant CRD schema involved, just Deployments and
a Service.

**Everything else self-heals, because Kubernetes controllers are
level-triggered** — they do not react to events, they continuously compare
desired against actual and keep retrying. Get these "wrong" and the cluster
converges anyway:

| Done out of order                    | What happens                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| Deploy before `kind load`            | `ImagePullBackOff`; the kubelet's next retry finds the newly loaded image and starts       |
| Backend before Postgres              | Fails its startupProbe / crash-loops, then succeeds once the database answers              |
| Backend before the `postgres-app` Secret exists | Pod stays `CreateContainerConfigError` until the operator writes the Secret, then starts |
| `k8s/base` before the ingress controller | `Ingress` object sits with no address; traffic starts flowing once step 2's Pod is ready |

Because apply is convergent rather than imperative, the fix for an ordering
mistake is almost always just to run `kubectl apply -k k8s/base` again. A
partial apply leaves the objects it _did_ create untouched and fills in the
rest.

```bash
# 1. Cluster: 1 control-plane + 3 labelled workers. The control-plane node
#    is also labelled ingress-ready=true and forwards host 8080 -> its own
#    port 80, which is where the ingress-nginx controller Pod will hostPort-
#    bind once it's scheduled there in step 2.
kind create cluster --config k8s/kind-cluster.yaml
kubectl config use-context kind-practice
kubectl get nodes -L practice.io/role,ingress-ready

# 2. ingress-nginx controller, kind's own provider manifest. It ships its own
#    nodeSelector (ingress-ready=true) and a toleration for the control-plane
#    taint, so the controller Pod lands on the one node with the port
#    mapping from step 1 -- no patching required, unlike the Gateway path.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# 3. CloudNativePG operator. This one IS order-dependent: it registers the
#    `postgresql.cnpg.io` CRDs, and until they exist the API server rejects
#    postgres-cluster.yaml outright -- no unfulfilled object, a hard error.
#    --server-side because the CRD schemas exceed the client-side annotation limit.
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
kubectl wait --namespace cnpg-system \
  --for=condition=Available deployment/cnpg-controller-manager \
  --timeout=180s

docker build --target runtime -t practice-backend:0.1.0  ./backend
docker build --target runtime -t practice-frontend:0.1.0 ./frontend
kind load docker-image practice-backend:0.1.0  --name practice
kind load docker-image practice-frontend:0.1.0 --name practice

kubectl apply -k k8s/base
kubectl wait --for=condition=Ready cluster/postgres -n practice --timeout=300s
kubectl rollout status deployment/backend   -n practice --timeout=300s
kubectl rollout status deployment/frontend  -n practice --timeout=300s

kubectl get pods -n practice -o wide          # note which node each landed on
kubectl get ingress -n practice
curl -s http://localhost:8080/api/health
curl -s http://localhost:8080/api/ready
curl -s http://localhost:8080/api/items
```

Then open <http://localhost:8080>.

## Tear down and rebuild

```bash
kind delete cluster --name practice
```

Everything in the cluster goes, **including the PVC and its data**. The next
boot finds an empty data directory, so the operator re-runs `initdb` and the
`postInitApplicationSQLRefs` files replay — you get the seed items back, but
anything added through the UI is gone. To keep real data,
`kubectl exec postgres-1 -n practice -- pg_dump ...` first.

What survives on your machine, so a rebuild is shorter than a first run:

|                                                      | Survives teardown? | Lives in                            |
| ---------------------------------------------------- | ------------------ | ----------------------------------- |
| The manifests and `kind-cluster.yaml`                | yes                | git                                 |
| `practice-backend:0.1.0` / `practice-frontend:0.1.0` | yes                | your **host** Docker daemon         |
| Cluster, CNPG operator, pods, PVC                    | no                 | gone                                |
| The generated DB password                            | no                 | regenerated on the next bootstrap   |

So on a rebuild you can skip the two
`docker build` commands (the images are still in Docker) — but you **must**
re-run `kind load`. New nodes have empty containerd stores. That is the split
worth remembering: `docker build` writes to your laptop and survives;
`kind load` writes into the cluster and dies with it.

Everything else is just steps 1-3, 5 and 6 again, verbatim. Roughly 3-4 minutes.

## What replaced what

| docker-compose.yml                   | Kubernetes                                           | Why it changed                                                                            |
| ------------------------------------ | ---------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `db` + `pgdata` volume               | `postgres-cluster.yaml` (CloudNativePG `Cluster`)    | An operator that understands Postgres owns the pods, PVCs, probes and failover — you declare intent, not mechanics. |
| `./db/init` bind mount               | `postgres-initdb` ConfigMap → `postInitApplicationSQLRefs` | No host filesystem to bind from. Same SQL, same order, still first-boot-only — but run by the operator after it creates the database and owner. |
| `backend`                            | `backend-deployment.yaml` + Service                  | —                                                                                         |
| `frontend`                           | `frontend-deployment.yaml` + Service                 | —                                                                                         |
| `nginx` edge + `ports: 8080:80`      | `ingress.yaml` + ingress-nginx controller            | Same nginx underneath. Your `location` blocks became `Ingress` `rules`; the controller is the thing that renders them into an actual nginx.conf. |
| `networks: edge / data / monitoring` | _nothing yet_                                        | Kubernetes has one flat pod network. Isolation is `NetworkPolicy` — see "Not done yet".   |
| `depends_on: service_healthy`        | _nothing_                                            | No ordering exists. `waitForDatabase()` in `backend/src/db.js` already handles it.        |
| `healthcheck:`                       | `livenessProbe` / `readinessProbe` / `startupProbe`  | One check split into three, because k8s asks three different questions.                   |
| `.env`                               | ConfigMaps + the operator-generated `postgres-app` Secret | Non-secret config and credentials separate on purpose — and the DB password now has no plaintext source on your disk at all. |
| `node-exporter`, `monitoring-tools`  | _dropped_                                            | Node metrics are a cluster-level concern (DaemonSet + Prometheus), not an app concern.    |

## Node layout

```
practice-control-plane   ingress-ready=true          -> ingress-nginx controller (host :8080 lands here)
practice-worker          practice.io/role=frontend   -> frontend x2
practice-worker2         practice.io/role=backend    -> backend x2
practice-worker3         practice.io/role=data       -> postgres-1 + PVC

(The nodes are named `practice-*`; only the kubectl CONTEXT is `kind-practice`.)
```

The `nodeSelector` pins are a **learning aid, not a production pattern**. Real clusters let the scheduler place pods by resource requests and spread them across nodes for availability. Pinning every workload to one node means one node failure takes that tier down completely.

To watch the scheduler take over, delete the three `nodeSelector` blocks and run:

```bash
kubectl apply -k k8s/base
kubectl get pods -n practice -o wide -w
```

## Traffic path

```
browser :8080
  -> kind extraPortMapping (host 8080 -> control-plane node port 80)
  -> ingress-nginx controller Pod (hostPort 80, scheduled via ingress-ready=true)
  -> Ingress rules
       /api  -> Service backend  :3000 -> backend pods  :3000
       /     -> Service frontend :80   -> frontend pods :80
```

## Everyday commands

```bash
# after changing code
docker build --target runtime -t practice-backend:0.1.0 ./backend
kind load docker-image practice-backend:0.1.0 --name practice
kubectl rollout restart deployment/backend -n practice   # kind load does NOT restart pods

# after changing k8s/base/initdb/*
kubectl delete cluster postgres -n practice
kubectl delete pvc postgres-1 -n practice
kubectl apply -k k8s/base

# read the generated app password
kubectl get secret postgres-app -n practice -o jsonpath='{.data.password}' | base64 -d; echo

# poke around
kubectl get cluster -n practice
kubectl exec -it postgres-1 -n practice -- psql -U postgres -d practicedb -c '\dt'
kubectl logs -n practice -l app=backend --prefix -f
kubectl describe pod -n practice -l app=backend    # Events section explains 90% of failures
```

## Troubleshooting

| Symptom                                                                        | Cause                                                                                                                                                                |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ErrImagePull` / `ImagePullBackOff`                                            | Image not loaded into kind, or `imagePullPolicy: Always`. Re-run `kind load docker-image <image> --name practice`.                                                   |
| Pod `Pending` forever                                                          | No node matches its `nodeSelector`. `kubectl get nodes -L practice.io/role`.                                                                                         |
| `curl localhost:8080` hangs                                                   | The ingress-nginx controller Pod isn't `Running` yet, or didn't land on the `ingress-ready=true` node. Check `kubectl get pods -n ingress-nginx -o wide`.            |
| Backend `CrashLoopBackOff`                                                     | Postgres not ready yet, and the retry budget ran out. Check `kubectl logs`; raise `DB_CONNECT_MAX_RETRIES`.                                                          |
| `no matches for kind "Cluster"` on apply                                       | The CNPG operator isn't installed yet. Run step 3 and re-apply.                                                                                                      |
| Backend `CreateContainerConfigError`                                           | The `postgres-app` Secret doesn't exist yet — the Cluster hasn't finished bootstrapping. `kubectl get cluster -n practice`.                                          |
| App can read `items` but `INSERT` fails with `permission denied`               | The post-init SQL ran as superuser, so the tables aren't owned by `app_rw`. See `k8s/base/initdb/03_ownership.sql`.                                                  |
| `curl localhost:8080` gives `404 not found` (nginx's own 404, not the app's)   | `Ingress` object doesn't exist or its `ingressClassName` doesn't match. Check `kubectl get ingress -n practice` and `kubectl get ingressclass`.                      |
| Init scripts didn't run                                                        | The data directory was not empty. They only ever run on a fresh volume.                                                                                              |

## Not done yet

- **NetworkPolicy** — your compose `data` network was `internal: true`, so nothing outside it could reach Postgres. That guarantee is currently _gone_: any pod in the cluster can open a socket to `postgres:5432`. Restoring it means a default-deny policy plus an allow-from-`app=backend` rule.
- **Resource-based scheduling** — drop the `nodeSelector` pins.
- **Postgres HA** — `instances: 1` and no backups. With CNPG in place both are now a few lines away: raise `instances` to 3 for streaming replication with automatic failover, and add `spec.backup` with an object-store target for WAL archiving and PITR.
- **TLS** — the ingress listens on plain HTTP only.
- **Gateway API alternative** — `k8s/base/gateway.yaml` and `httproute.yaml` still exist, commented out of `kustomization.yaml`. They express the same two routes through NGINX Gateway Fabric instead of ingress-nginx, if you want to compare the two front doors side by side later.
