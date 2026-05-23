# Option 2: Deploy the NetBox Community Image

Skip the build step and pull the upstream [netboxcommunity/netbox](https://github.com/netbox-community/netbox-docker) image directly from Quay. This is the fastest path if you don't need custom patches.

## Prerequisites

- OpenShift cluster with `oc` CLI configured
- A container registry (internal Quay or public `quay.io`)
- Network access to pull images from the registry

## Step 1: Pull the Community Image

### From public Quay

```bash
# Pull the official netbox-docker image
podman pull quay.io/netboxcommunity/netbox:<version>

# Retag for your internal registry (optional)
podman tag quay.io/netboxcommunity/netbox:<version> \
  <registry>/<org>/netbox:<version>

# Push to internal registry
podman push <registry>/<org>/netbox:<version>
```

### Direct pull on OpenShift

If your cluster has network access to public registries, you can use the public image directly in your deployment manifests without mirroring:

```yaml
image: quay.io/netboxcommunity/netbox:3.4.1
```

## Step 2: Mirror to Internal Registry (Recommended)

For air-gapped or restricted environments, mirror the image to your internal registry:

```bash
# Login to source registry (if needed)
podman login quay.io

# Login to destination registry
podman login <registry>

# Mirror the image
podman pull quay.io/netboxcommunity/netbox:<version>
podman tag quay.io/netboxcommunity/netbox:<version> \
  <registry>/<org>/netbox:<version>
podman push <registry>/<org>/netbox:<version>
```

## Step 3: Create Image Pull Secret

If your internal registry requires authentication:

```bash
oc create secret docker-registry netbox-image-pull-secret \
  --docker-server=<registry> \
  --docker-username=<robot-account> \
  --docker-password=<token> \
  --namespace=netbox
```

Or apply the provided manifest:

```bash
oc apply -f manifests/netbox-image-pull-secret.yaml
```

## Step 4: Update Deployment Manifest

Edit `manifests/netbox.yaml` to use the community image:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: netbox-image-pull-secret
      containers:
      - name: netbox
        image: <registry>/<org>/netbox:<version>
```

## Step 5: Deploy

Follow the [OpenShift manifests guide](openshift-manifests.md) to apply all resources.

## Community Image vs. Custom Build

| | Community Image | Custom Build |
|---|---|---|
| Build time | None | 5-15 minutes |
| Patches | Upstream only | Custom patches |
| Registry | Public or mirrored | Internal only |
| Python version | Whatever upstream uses | Your choice (22.04/24.04) |
| Best for | Quick deployments | Production with custom needs |

## Version Compatibility

The community image follows the same version compatibility rules:

| NetBox Version | Base Image | Python |
|---------------|------------|--------|
| 3.4.1 | Ubuntu 22.04 | 3.10 |
| 4.x+ | Ubuntu 24.04 | 3.12 |

Use `quay.io/netboxcommunity/netbox:3.4.1` for the 3.4.1 release.
