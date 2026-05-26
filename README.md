# Deploy NetBox on OpenShift

Build, push, and deploy [NetBox](https://github.com/netbox-community/netbox) on OpenShift via container images.

## Quick Start — One-Command Install

The `scripts/install.sh` script pulls the NetBox community image, pushes it to your registry, and deploys everything on OpenShift:

```bash
./scripts/install.sh \
  --netbox-version 3.4.1 \
  --quay-host registry-quay-quay-enterprise.apps.luke.syangsao.net \
  --quay-repo openshift/netbox \
  --quay-user openshift+robot \
  --quay-pass "YOUR_ROBOT_TOKEN" \
  --namespace netbox \
  --admin-password admin \
  --storage-class nfs-csidriver3
```

See [install.sh options](#install-script-options) for all flags.

---

## Three Ways to Deploy

| Approach | When to use | Guide |
|---|---|---|
| **1. Build from source** | Full control, custom patches, air-gapped | [docs/build-from-source.md](docs/build-from-source.md) |
| **2. Community image** | Fastest path, no custom patches needed | [docs/community-image.md](docs/community-image.md) |
| **3. OpenShift manifests** | Manual `oc apply` deployment | [docs/openshift-manifests.md](docs/openshift-manifests.md) |

---

## Install Script Options

| Option | Description | Default |
|---|---|---|
| `--netbox-version VERSION` | NetBox version | `3.4.1` |
| `--quay-host HOST` | Quay registry hostname | (required) |
| `--quay-repo REPO` | Quay repo path (e.g. `openshift/netbox`) | (required) |
| `--quay-user USER` | Quay username | (required) |
| `--quay-pass PASS` | Quay password/token | (required) |
| `--namespace NAME` | OpenShift namespace | `netbox` |
| `--admin-password PASS` | Admin password | `admin` |
| `--storage-class CLASS` | PVC storage class | Auto-detected (cluster default) |
| `--dry-run` | Show config only, do not deploy | false |

### What the script deploys

```
Route (TLS/edge)
    │
    ▼
NetBox Service (port 8080)
    │
    ├── NetBox App (Granian, 4 workers)
    ├── NetBox Worker (RQ sidecar)
    │
    ├── PostgreSQL 18 (persistent, 10Gi)
    ├── Redis Sessions (Valkey 9, persistent, 5Gi)
    └── Redis Cache (Valkey 9, persistent, 5Gi)

PVCs: postgres (10Gi), redis sessions (5Gi), redis cache (5Gi),
      media (10Gi), reports (1Gi), scripts (1Gi)
Storage class: auto-detected from cluster default, override with --storage-class
```

---

## Python / Django / Ubuntu Compatibility

| Base Image | Python | Django Required | NetBox Versions |
|---|---|---|---|
| **Ubuntu 24.04** | 3.12 | ≥ 4.2 | 4.3+ |
| **Ubuntu 22.04** | 3.10 | 3.2 — 4.2 | 3.4.x, 4.0 — 4.3 |

> **⚠️ NetBox 3.4.x is not compatible with Ubuntu 24.04** — Django 3.2.x doesn't support Python 3.12. Use Ubuntu 22.04 for NetBox 3.x.
>
> Full details: [docs/build-from-source.md](docs/build-from-source.md)

---

## Directory Structure

```
openshift_netbox/
├── README.md                    # This file
├── docs/
│   ├── build-from-source.md     # Build custom images with podman
│   ├── community-image.md       # Deploy upstream community image
│   └── openshift-manifests.md   # Manual oc apply deployment
├── scripts/
│   └── install.sh               # One-command install
├── build/
│   ├── build-and-push.sh        # Build with Ubuntu 22.04 base
│   └── build-and-push-24.04.sh  # Build with Ubuntu 24.04 base
├── docker/
│   ├── docker-entrypoint.sh     # Container entrypoint
│   ├── launch-netbox.sh         # Launch script (Ubuntu 24.04)
│   └── launch-netbox-2204.sh    # Launch script (Ubuntu 22.04)
└── manifests/
    ├── netbox-config.yaml       # Configuration ConfigMap
    ├── netbox-env.yaml          # Environment variables Secret
    ├── netbox-image-pull-secret.yaml  # Image pull secret template
    ├── postgres.yaml            # PostgreSQL deployment + PVC
    ├── redis.yaml               # Redis session store + PVC
    ├── redis-cache.yaml         # Redis cache + PVC
    ├── netbox.yaml              # NetBox app + worker deployment
    └── route.yaml               # OpenShift Route (TLS ingress)
```

---

## Troubleshooting

Common issues and fixes are documented in the guides:

- **Build failures** — [docs/build-from-source.md](docs/build-from-source.md)
- **Deployment issues** — [docs/openshift-manifests.md](docs/openshift-manifests.md)

Quick references:

| Error | Likely cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Bad pull secret or image not in registry | Check secret, verify image exists |
| `TypeError: unhashable type: 'dict'` | DATABASE/REDIS in wrong config file | Move to `configuration.docker.py` |
| `ModuleNotFoundError: django.utils.itercompat` | NetBox 3.x on Ubuntu 24.04 | Use Ubuntu 22.04 base |
| `pkg_resources not found` | Missing setuptools | Use `pip uninstall`, not `rm -rf` |
| `ZoneInfoNotFoundError` | Missing tzdata | Add `tzdata` to Dockerfile apt install |

---

## References

- [NetBox Docker](https://github.com/netbox-community/netbox-docker)
- [NetBox Docs](https://docs.netbox.dev/)
- [Quay.io Docs](https://docs.quay.io/)
- [OpenShift Networking](https://docs.openshift.com/latest/networking/index.html)
