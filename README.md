# Deploy NetBox on OpenShift via Quay.io

A step-by-step guide to build the [NetBox Docker image](https://github.com/netbox-community/netbox-docker), push it to Quay.io, and deploy it on OpenShift.

## Architecture

```
Route (TLS/edge)
    │
    ▼
NetBox Service (port 8080)
    │
    ├── NetBox App (Granian, 4 workers)
    ├── NetBox Worker (RQ sidecar)
    │
    ├── PostgreSQL 18 (persistent)
    ├── Redis Sessions (Valkey 9, persistent)
    └── Redis Cache (Valkey 9, persistent)
```

## Prerequisites

- **Docker** with Buildx enabled
- **Quay.io** account with a repository
- **OpenShift** cluster access (`oc` CLI configured)
- **Docker login** to Quay: `docker login quay.io`

---

## Step 1: Build the Container Image

### Clone the NetBox Docker repo

```bash
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker
```

### Set build variables

```bash
# Choose the NetBox version tag (e.g., v4.3.0, v4.2.0, v4.1.0)
export NETBOX_VERSION=v4.3.0

# Your Quay.io organization/repository
export QUAY_ORG=your-quay-org
```

### Build locally (dry run)

```bash
IMAGE_NAMES="quay.io/${QUAY_ORG}/netbox" \
  DOCKER_FROM=docker.io/ubuntu:24.04 \
  ./build.sh ${NETBOX_VERSION}
```

This clones the NetBox source at the specified version, builds the image, and tags it. Verify it works:

```bash
docker run --rm quay.io/${QUAY_ORG}/netbox:${NETBOX_VERSION} --help
```

### Push to Quay

```bash
IMAGE_NAMES="quay.io/${QUAY_ORG}/netbox" \
  DOCKER_FROM=docker.io/ubuntu:24.04 \
  ./build.sh ${NETBOX_VERSION} --push
```

The `--push` flag switches the output mode from `type=docker` to `type=image --push`, sending the image directly to Quay.

### Build Variables Reference

| Variable | Default | Description |
|---|---|---|
| `NETBOX_VERSION` | (required) | Git tag or branch of NetBox source |
| `IMAGE_NAMES` | `docker.io/netboxcommunity/netbox` | Target registry image name(s) |
| `DOCKER_FROM` | `ubuntu:26.04` | Base image (use `ubuntu:24.04` for OpenShift 4) |
| `BUILDX_PLATFORM` | `linux/amd64` | Target platform(s) |
| `BUILDX_BUILDER_NAME` | `(auto)` | Buildx builder name |

---

## Step 2: Prepare OpenShift

### Create the project

```bash
oc new-project netbox
```

### Create an ImagePullSecret (if Quay is private)

```bash
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_TOKEN \
  --docker-email=you@example.com

# Attach to the default ServiceAccount
oc patch sa default -n netbox \
  -p '{"imagePullSecrets": [{"name": "quay-pull-secret"}]}'
```

---

## Step 3: Deploy Manifests

All manifests live in the `manifests/` directory. Apply them in order.

### 3a. Configuration (ConfigMap + Secret)

```bash
oc apply -f manifests/netbox-config.yaml
oc apply -f manifests/netbox-env.yaml
```

**Important**: Edit `manifests/netbox-env.yaml` and set **real passwords** and a **strong SECRET_KEY** (minimum 50 characters). The defaults are placeholders.

### 3b. Database and Cache

```bash
# PostgreSQL (with PVC)
oc apply -f manifests/postgres.yaml

# Redis session store (with PVC)
oc apply -f manifests/redis.yaml

# Redis cache (with PVC)
oc apply -f manifests/redis-cache.yaml
```

### 3c. Wait for dependencies

```bash
oc wait --for=condition=ready pod -l app=netbox-postgres -n netbox --timeout=120s
oc wait --for=condition=ready pod -l app=netbox-redis -n netbox --timeout=60s
oc wait --for=condition=ready pod -l app=netbox-redis-cache -n netbox --timeout=60s
```

### 3d. NetBox App + Worker

Edit `manifests/netbox.yaml` and replace `quay.io/YOUR_ORG/netbox:v4.3.0` with your actual image path.

```bash
oc apply -f manifests/netbox.yaml
```

### 3e. Route (Ingress)

```bash
oc apply -f manifests/route.yaml
```

### 3f. Verify

```bash
oc get pods -n netbox
oc get route netbox -n netbox -o jsonpath='{.spec.host}'
```

Visit the URL in your browser. The first startup takes ~90 seconds for migrations and superuser creation.

---

## Step 4: Post-Deployment

### Access the UI

```bash
# Get the route URL
oc get route netbox -n netbox -o jsonpath='{.spec.host}'
# e.g., https://netbox-netbox.apps.cluster.example.com
```

Default admin credentials (from `netbox-env.yaml`):
- **Username**: `admin`
- **Password**: whatever you set for `SUPERUSER_PASSWORD`

### Scale the App

To add more replicas of the app (worker stays at 1):

```bash
oc scale deployment netbox -n netbox --replicas=2
```

### Update NetBox Version

1. Rebuild and push a new image tag to Quay (Step 1)
2. Update the image in `manifests/netbox.yaml`
3. Apply: `oc apply -f manifests/netbox.yaml`

---

## Directory Structure

```
openshift_netbox/
├── README.md                    # This guide
├── build/
│   └── build-and-push.sh        # Helper script for Step 1
└── manifests/
    ├── netbox-config.yaml       # Configuration ConfigMap
    ├── netbox-env.yaml          # Environment variables Secret
    ├── postgres.yaml            # PostgreSQL deployment + PVC
    ├── redis.yaml               # Redis session store + PVC
    ├── redis-cache.yaml         # Redis cache + PVC
    ├── netbox.yaml              # NetBox app + worker deployment
    └── route.yaml               # OpenShift Route (TLS ingress)
```

---

## Troubleshooting

### Pod stuck on ImagePullBackOff
Check the ImagePullSecret:
```bash
oc describe pod <netbox-pod> -n netbox | grep -A5 "Failed to pull"
oc get sa default -n netbox -o yaml | grep imagePullSecrets
```

### Pod stuck on CrashLoopBackOff
Check logs:
```bash
oc logs <netbox-pod> -n netbox -c netbox
oc logs <netbox-pod> -n netbox -c netbox-worker
```
Common causes: wrong DB password, invalid SECRET_KEY format, or DB not ready.

### Readiness probe failing
The probe checks `/login/` on port 8080 with a 90-second initial delay. If the first startup takes longer (large migrations), increase `initialDelaySeconds` in `manifests/netbox.yaml`.

---

## References

- [NetBox Docker](https://github.com/netbox-community/netbox-docker)
- [NetBox Docs](https://docs.netbox.dev/)
- [Quay.io Docs](https://docs.quay.io/)
- [OpenShift Networking Guide](https://docs.openshift.com/latest/networking/index.html)
