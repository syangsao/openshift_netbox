# Deploy NetBox on OpenShift

A step-by-step guide to build the [NetBox Docker image](https://github.com/netbox-community/netbox-docker), push it to a container registry, and deploy it on OpenShift.

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

- **Podman** installed (`podman build`/`podman push`)
- **Container registry** account with a repository
- **OpenShift** cluster access (`oc` CLI configured)
- **Podman login** to registry: `podman login ${REGISTRY}`

---

## Step 1: Build the Container Image

### Clone the NetBox Docker repo

```bash
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker
```

### Set build variables

```bash
# Container registry (default: quay.io)
export REGISTRY=quay.io

# Choose the NetBox version tag (no "v" prefix — e.g., 4.3.0, 4.2.0, 4.1.0)
export NETBOX_VERSION=4.3.0

# Your registry organization
export REGISTRY_ORG=your-registry-org
```

### Manual Build Steps

```bash
git clone https://github.com/netbox-community/netbox-docker.git
cd netbox-docker

# 1. Checkout the netbox-docker version
git fetch --tags
git tag -l | sort -V | tail -20
git checkout ${NETBOX_VERSION}

# 2. Clone the NetBox source code (required — Dockerfile needs it)
# The netbox source repo uses v-prefixed tags (v4.0.2, not 4.0.2)
git clone --depth 1 --branch "v${NETBOX_VERSION}" \
  https://github.com/netbox-community/netbox.git .netbox

# 3. Patch the Dockerfile
# Add libjpeg-dev for Pillow build, fix social-auth-core bracket handling
# IMPORTANT: Use TWO separate sed -i calls (combining -e fails)
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile
sed -i -e 's|social-auth-core/social-auth-core\\\[all\\\]|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g' Dockerfile

# 4. Fix sentry-sdk version conflict (required for NetBox 3.4.x builds)
sed -i '/^sentry-sdk==/d' .netbox/requirements.txt

# 5. Fix PyYAML 6.0 build failure (cannot build with modern setuptools)
sed -i '/^PyYAML==/d' .netbox/requirements.txt

# 6. Fix Pillow build failure (needs libjpeg-dev headers)
sed -i '/^Pillow==/d' .netbox/requirements.txt

# 7. Fix django-auth-ldap version conflict (required for NetBox 3.4.x builds)
sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt

# 8. Verify the patches took effect
grep libjpeg-dev Dockerfile
# social-auth-core sed in Dockerfile should show: social-auth-core\[[^]]*\]

# 9. Build (--no-cache prevents podman from using stale cached layers)
podman build \
  --no-cache \
  --pull \
  --target main \
  -f Dockerfile \
  -t "${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}" \
  --build-arg "FROM=docker.io/ubuntu:24.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  .
```

This clones both repos, patches the Dockerfile for package name compatibility, builds the image, and tags it. Verify it works:

```bash
podman run --rm ${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION} --help
```

### Push to Registry

```bash
podman push ${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}
```

Or use the convenience scripts which handle everything automatically:

```bash
# Ubuntu 24.04 base (recommended)
./build/build-and-push-24.04.sh ${NETBOX_VERSION} ${REGISTRY_ORG} ${REGISTRY}

# Ubuntu 22.04 base
./build/build-and-push.sh ${NETBOX_VERSION} ${REGISTRY_ORG} ${REGISTRY}
```

### Build Variables Reference

| Variable | Default | Description |
|---|---|---|
| `REGISTRY` | `quay.io` | Container registry host |
| `REGISTRY_ORG` | (required) | Your registry organization |
| `FROM` | `docker.io/ubuntu:24.04` | Base image |

---

## Step 2: Prepare OpenShift

### Create the project

```bash
oc new-project netbox
```

### Create an ImagePullSecret (if registry is private)

```bash
oc create secret docker-registry registry-pull-secret \
  --docker-server=${REGISTRY} \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_TOKEN \
  --docker-email=you@example.com

# Attach to the default ServiceAccount
oc patch sa default -n netbox \
  -p '{"imagePullSecrets": [{"name": "registry-pull-secret"}]}'
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

Edit `manifests/netbox.yaml` and replace `${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}` with your actual image path.

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

1. Rebuild and push a new image tag (Step 1)
2. Update the image in `manifests/netbox.yaml`
3. Apply: `oc apply -f manifests/netbox.yaml`

---

## Directory Structure

```
openshift_netbox/
├── README.md                    # This guide
├── build/
│   ├── build-and-push.sh        # Build with Ubuntu 22.04 base
│   └── build-and-push-24.04.sh  # Build with Ubuntu 24.04 base (patches Dockerfile)
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

### podman build fails with `RequiredDependencyException: jpeg`

Pillow needs `libjpeg-dev` headers to build from source. The Dockerfile doesn't install it.

**Fix:** Add `libjpeg-dev` to the apt-get install list and remove the Pillow pin:

```bash
cd netbox-docker
sed -i '/libxslt-dev/i\      libjpeg-dev \\' Dockerfile
sed -i '/^Pillow==/d' .netbox/requirements.txt
```

### podman build fails with `social-auth-core` double brackets

The upstream Dockerfile sed creates `social-auth-core[[all]]` instead of `social-auth-core[all]`.

**Fix:** Patch the Dockerfile sed command (use TWO separate sed calls):

```bash
cd netbox-docker
sed -i -e 's|social-auth-core/social-auth-core\\\[all\\\]|social-auth-core\\[[^]]*\\]/social-auth-core[all]|g' Dockerfile
```

### podman build fails with dependency conflicts

See the [Manual Build Steps](#manual-build-steps) section for all required patches.

**Quick fix** — use the convenience script which handles everything:

```bash
cd netbox-docker
git checkout v${NETBOX_VERSION}

git clone --depth 1 --branch "v${NETBOX_VERSION}" \
  https://github.com/netbox-community/netbox.git .netbox

# Build (--no-cache is critical to avoid stale cached layers)
podman build \
  --pull \
  --no-cache \
  --target main \
  -f Dockerfile \
  -t "${REGISTRY}/${REGISTRY_ORG}/netbox:${NETBOX_VERSION}" \
  --build-arg "FROM=docker.io/ubuntu:24.04" \
  --build-arg "NETBOX_PATH=.netbox" \
  .
```

> Note: netbox-docker 3.4.1+ already uses correct `libxmlsec1` and `libxmlsec1-openssl`
> package names — no renaming patches needed for these versions.

### podman build fails with `sentry-sdk` version conflict
```
Because you require sentry-sdk==1.11.1 and sentry-sdk[django]==2.39.0,
we can conclude that your requirements are unsatisfiable.
```
NetBox source `.netbox/requirements.txt` pins `sentry-sdk==1.11.1` but netbox-docker's
`requirements-container.txt` requires `sentry-sdk[django]>=2.x`. Fix by removing
the hard pin from the NetBox source requirements:

```bash
sed -i '/^sentry-sdk==/d' .netbox/requirements.txt
```

### podman build fails with `django-auth-ldap` version conflict
```
Because django-auth-ldap==5.2.0 depends on django>=4.2 and you require django==4.1.4,
we can conclude that your requirements are unsatisfiable.
```
netbox-docker's `requirements-container.txt` pins `django-auth-ldap==5.2.0` which
requires `django>=4.2`, but NetBox 3.4.x source doesn't pin `django>=4.2` so uv
resolves `django==4.1.4`. Fix by downgrading django-auth-ldap:

```bash
sed -i 's/^django-auth-ldap==5.2.0$/django-auth-ldap==4.8.0/' requirements-container.txt
```

### podman build fails with `pyyaml` build failure
```
AttributeError: 'build_ext' object has no attribute 'cython_sources'
```
PyYAML 6.0 requires Cython to build from source but doesn't declare it as a
build dependency. Remove the hard pin so uv resolves to a newer version with
pre-built wheels:

```bash
sed -i '/^PyYAML==/d' .netbox/requirements.txt
```

### podman build fails with `social-auth-core[all][openidconnect]`
The upstream Dockerfile's sed command creates double brackets when `requirements.txt` already has `social-auth-core[openidconnect]` (NetBox 3.4.x and newer). The build scripts handle this automatically. For manual builds, the sed patch above (`social-auth-core\[*\]/social-auth-core[all]`) replaces any existing extras bracket with `[all]`.

---

## References

- [NetBox Docker](https://github.com/netbox-community/netbox-docker)
- [NetBox Docs](https://docs.netbox.dev/)
- [Quay.io Docs](https://docs.quay.io/)
- [OpenShift Networking Guide](https://docs.openshift.com/latest/networking/index.html)
