# Option 3: Deploy via OpenShift Manifests

Apply the YAML manifests with `oc` to create all NetBox resources on OpenShift. This guide follows the same steps that `scripts/install.sh` performs, but manually.

## Prerequisites

- OpenShift cluster with `oc` CLI configured and logged in
- NetBox image available in your registry (see [build-from-source.md](build-from-source.md) or [community-image.md](community-image.md))
- `podman` or `docker` CLI installed (for pulling and pushing images)

## Step 1: Pull and Push the Image

Pull the NetBox community image and push it to your registry:

```bash
# Pull from Docker Hub
podman pull docker.io/netboxcommunity/netbox:latest-3.4.1

# Tag for your registry
podman tag docker.io/netboxcommunity/netbox:latest-3.4.1 \
  <registry>/<org>/netbox:3.4.1

# Login and push
podman login <registry>
podman push <registry>/<org>/netbox:3.4.1
```

## Step 2: Choose a Storage Class

All PVCs (PostgreSQL, Redis sessions, Redis cache, media, reports, scripts) need a storage class. Check what's available:

```bash
oc get sc
```

Pick one — the one marked `(default)` is a safe choice. Note it for the PVC steps below.

## Step 3: Create Namespace

```bash
oc create namespace netbox --dry-run=client -o yaml | oc apply -f -
```

## Step 4: Create Image Pull Secret

```bash
oc create secret docker-registry netbox-image-pull-secret \
  --docker-server=<registry> \
  --docker-username=<robot-account> \
  --docker-password=<token> \
  --docker-email=install@netbox \
  --namespace=netbox
```

## Step 5: Generate Credentials

Generate random passwords and a secret key:

```bash
DB_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
REDIS_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
REDIS_CACHE_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(64))")
ADMIN_PASSWORD="admin"  # Change this!
```

Create the `netbox-env` secret:

```bash
oc create secret generic netbox-env \
  --from-literal=DB_HOST=netbox-postgres \
  --from-literal=DB_NAME=netbox \
  --from-literal=DB_USER=netbox \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=REDIS_HOST=netbox-redis \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=REDIS_CACHE_HOST=netbox-redis-cache \
  --from-literal=REDIS_CACHE_PASSWORD="$REDIS_CACHE_PASSWORD" \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=SKIP_SUPERUSER=false \
  --from-literal=SUPERUSER_NAME=admin \
  --from-literal=SUPERUSER_PASSWORD="$ADMIN_PASSWORD" \
  --from-literal=SUPERUSER_EMAIL=admin@example.com \
  --from-literal=GRANIAN_WORKERS=4 \
  --from-literal=GRANIAN_BACKPRESSURE=4 \
  --from-literal=CORS_ORIGIN_ALLOW_ALL=True \
  --namespace=netbox
```

## Step 6: Create ConfigMap

```bash
cat <<'EOF' | oc apply -n netbox -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: netbox-config
data:
  configuration.py: |
    #!/usr/bin/env python
    import os
    from netbox.configuration import *

    ALLOWED_HOSTS = ['*']
    STATIC_URL = "/"
    SECRET_KEY = os.environ.get('SECRET_KEY', '')
    GRAPHQL_ENABLED = True
    WEBHOOKS_ENABLED = True

  configuration.docker.py: |
    #!/usr/bin/env python
    import os

    DATABASE = {
        'NAME': os.environ.get('DB_NAME', 'netbox'),
        'USER': os.environ.get('DB_USER', 'netbox'),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', 'netbox-postgres'),
        'PORT': int(os.environ.get('DB_PORT', 5432)),
        'CONN_MAX_AGE': int(os.environ.get('DB_CONN_MAX_AGE', 300)),
    }

    REDIS = {
        'tasks': {
            'HOST': os.environ.get('REDIS_HOST', 'netbox-redis'),
            'PORT': int(os.environ.get('REDIS_PORT', 6379)),
            'PASSWORD': os.environ.get('REDIS_PASSWORD', ''),
            'DATABASE': 0,
            'CONN_MAX_AGE': int(os.environ.get('REDIS_CONN_MAX_AGE', 300)),
            'SSL': os.environ.get('REDIS_SSL', 'false').lower() == 'true',
        },
        'caching': {
            'HOST': os.environ.get('REDIS_CACHE_HOST', 'netbox-redis-cache'),
            'PORT': int(os.environ.get('REDIS_CACHE_PORT', 6379)),
            'PASSWORD': os.environ.get('REDIS_CACHE_PASSWORD', ''),
            'DATABASE': 1,
            'CONN_MAX_AGE': int(os.environ.get('REDIS_CACHE_CONN_MAX_AGE', 300)),
            'SSL': os.environ.get('REDIS_CACHE_SSL', 'false').lower() == 'true',
        }
    }
EOF
```

> **Important:** `DATABASE` and `REDIS` **must** be in `configuration.docker.py`, not `configuration.py`. The netbox-docker entrypoint merges configs and fails with `TypeError: unhashable type: 'dict'` if they appear in the base config.

## Step 7: Deploy PostgreSQL

```bash
STORAGE_CLASS="<your-storage-class>"

cat <<EOF | oc apply -n netbox -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-postgres-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: Service
metadata:
  name: netbox-postgres
  labels:
    app: netbox-postgres
spec:
  ports:
    - port: 5432
      targetPort: 5432
      name: postgres
  selector:
    app: netbox-postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbox-postgres
  labels:
    app: netbox-postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: netbox-postgres
  template:
    metadata:
      labels:
        app: netbox-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18-alpine
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: netbox-env
          env:
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: netbox-env
                  key: DB_NAME
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: netbox-env
                  key: DB_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: netbox-env
                  key: DB_PASSWORD
          volumeMounts:
            - name: run-tmp
              mountPath: /run
            - name: postgres-data
              mountPath: /var/lib/postgresql
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          readinessProbe:
            exec:
              command: [pg_isready, -q, -d, netbox, -U, netbox]
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
      volumes:
        - name: run-tmp
          emptyDir: {}
        - name: postgres-data
          persistentVolumeClaim:
            claimName: netbox-postgres-pvc
EOF
```

Wait for PostgreSQL:

```bash
oc wait --for=condition=ready pod -l app=netbox-postgres -n netbox --timeout=180s
```

## Step 8: Deploy Redis (Sessions)

```bash
cat <<EOF | oc apply -n netbox -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-redis-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: Service
metadata:
  name: netbox-redis
  labels:
    app: netbox-redis
spec:
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
  selector:
    app: netbox-redis
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbox-redis
  labels:
    app: netbox-redis
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: netbox-redis
  template:
    metadata:
      labels:
        app: netbox-redis
    spec:
      containers:
        - name: redis
          image: valkey/valkey:9.0-alpine
          command: [sh, -c, "valkey-server --appendonly yes --requirepass \${REDIS_PASSWORD}"]
          envFrom:
            - secretRef:
                name: netbox-env
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: netbox-env
                  key: REDIS_PASSWORD
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: redis-data
              mountPath: /data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: redis-data
          persistentVolumeClaim:
            claimName: netbox-redis-pvc
EOF
```

## Step 9: Deploy Redis (Cache)

```bash
cat <<EOF | oc apply -n netbox -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-redis-cache-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: Service
metadata:
  name: netbox-redis-cache
  labels:
    app: netbox-redis-cache
spec:
  ports:
    - port: 6379
      targetPort: 6379
      name: redis
  selector:
    app: netbox-redis-cache
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbox-redis-cache
  labels:
    app: netbox-redis-cache
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: netbox-redis-cache
  template:
    metadata:
      labels:
        app: netbox-redis-cache
    spec:
      containers:
        - name: redis-cache
          image: valkey/valkey:9.0-alpine
          command: [sh, -c, "valkey-server --requirepass \${REDIS_CACHE_PASSWORD}"]
          env:
            - name: REDIS_CACHE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: netbox-env
                  key: REDIS_CACHE_PASSWORD
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: redis-cache-data
              mountPath: /data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: redis-cache-data
          persistentVolumeClaim:
            claimName: netbox-redis-cache-pvc
EOF
```

Wait for Redis:

```bash
oc wait --for=condition=ready pod -l app=netbox-redis -n netbox --timeout=120s
oc wait --for=condition=ready pod -l app=netbox-redis-cache -n netbox --timeout=120s
```

## Step 10: Deploy NetBox

```bash
NETBOX_IMAGE="<registry>/<org>/netbox:3.4.1"

cat <<EOF | oc apply -n netbox -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-media-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-reports-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-scripts-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: $STORAGE_CLASS
---
apiVersion: v1
kind: Service
metadata:
  name: netbox
  labels:
    app: netbox
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  selector:
    app: netbox
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netbox
  labels:
    app: netbox
spec:
  replicas: 1
  selector:
    matchLabels:
      app: netbox
  template:
    metadata:
      labels:
        app: netbox
    spec:
      imagePullSecrets:
        - name: netbox-image-pull-secret
      containers:
        - name: netbox
          image: $NETBOX_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8080
              name: http
          envFrom:
            - secretRef:
                name: netbox-env
          volumeMounts:
            - name: config
              mountPath: /etc/netbox/config
              readOnly: true
            - name: media
              mountPath: /opt/netbox/netbox/media
            - name: reports
              mountPath: /opt/netbox/netbox/reports
            - name: scripts
              mountPath: /opt/netbox/netbox/scripts
          readinessProbe:
            httpGet:
              path: /login/
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /login/
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 3
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
        - name: netbox-worker
          image: $NETBOX_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          envFrom:
            - secretRef:
                name: netbox-env
          command:
            - /opt/netbox/venv/bin/python
            - /opt/netbox/netbox/manage.py
            - rqworker
          volumeMounts:
            - name: config
              mountPath: /etc/netbox/config
              readOnly: true
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: config
          configMap:
            name: netbox-config
        - name: media
          persistentVolumeClaim:
            claimName: netbox-media-pvc
        - name: reports
          persistentVolumeClaim:
            claimName: netbox-reports-pvc
        - name: scripts
          persistentVolumeClaim:
            claimName: netbox-scripts-pvc
EOF
```

## Step 11: Create Route

```bash
cat <<EOF | oc apply -n netbox -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: netbox
  labels:
    app: netbox
spec:
  to:
    kind: Service
    name: netbox
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

## Step 12: Wait for NetBox

```bash
oc wait --for=condition=ready pod -l app=netbox -n netbox --timeout=600s
```

First startup takes ~5 minutes for migrations and superuser creation.

## Step 13: Verify

```bash
# Check all pods
oc get pods -n netbox

# Get the URL
oc get route netbox -n netbox -o jsonpath='{.spec.host}'

# Health check
curl -sk https://$(oc get route netbox -n netbox -o jsonpath='{.spec.host}')/login/ | head -5
```

Expected output — all pods running:

```
NAME                                  READY   STATUS    RESTARTS   AGE
netbox-xxxxx-xxxxx                    2/2     Running   0          5m
netbox-postgres-xxxxx-xxxxx           1/1     Running   0          6m
netbox-redis-xxxxx-xxxxx              1/1     Running   0          6m
netbox-redis-cache-xxxxx-xxxxx        1/1     Running   0          6m
```

## PVC Summary

| PVC | Size | Purpose |
|---|---|---|
| `netbox-postgres-pvc` | 10Gi | PostgreSQL data |
| `netbox-redis-pvc` | 5Gi | Redis session store (AOF persistence) |
| `netbox-redis-cache-pvc` | 5Gi | Redis cache |
| `netbox-media-pvc` | 10Gi | NetBox media/uploads |
| `netbox-reports-pvc` | 1Gi | NetBox reports |
| `netbox-scripts-pvc` | 1Gi | NetBox custom scripts |

## Troubleshooting

### `ImagePullBackOff`

```bash
oc describe pod netbox-xxxxx -n netbox | grep -A5 "Events"
podman manifest inspect <registry>/<org>/netbox:<version>
```

Make sure `imagePullSecrets` is set on the NetBox deployment and the secret references a valid robot account.

### `CrashLoopBackOff` — NetBox container

```bash
oc logs netbox-xxxxx -n netbox -c netbox --tail=30
oc logs netbox-xxxxx -n netbox -c netbox-worker --tail=30
```

Common causes:
- **`TypeError: unhashable type: 'dict'`** — DATABASE/REDIS in wrong config file. Move to `configuration.docker.py`.
- **`ModuleNotFoundError: No module named 'django.utils.itercompat'`** — NetBox 3.x on Ubuntu 24.04. Use Ubuntu 22.04 base.
- **`ZoneInfoNotFoundError`** — Missing `tzdata` package in image.
- **`pkg_resources` not found** — `setuptools` missing from image.

### `CrashLoopBackOff` — PostgreSQL

```bash
oc logs -l app=netbox-postgres -n netbox --tail=20
```

Common causes:
- **subPath conflict** — Don't use `subPath` with NFS-CSI + restricted SCC. Mount the full PVC volume.
- **Permission denied** — NFS mount ownership conflicts with OpenShift random UID.

### PVC Stuck in `Pending`

```bash
oc describe pvc netbox-postgres-pvc -n netbox
oc delete pvc netbox-postgres-pvc -n netbox --force --grace-period=0
```

### Secret Changes Not Picked Up

OpenShift doesn't automatically reload pods when secrets change:

```bash
oc rollout restart deployment/netbox -n netbox
```

### Superuser Already Exists

If you redeploy and get `User with this username already exists`:

```bash
oc set env secret/netbox-env SKIP_SUPERUSER=true -n netbox
oc rollout restart deployment/netbox -n netbox
```

## One-Command Alternative

For a fully automated deployment, use `scripts/install.sh`:

```bash
./scripts/install.sh \
  --netbox-version 3.4.1 \
  --quay-host registry.example.com \
  --quay-repo myorg/netbox \
  --quay-user robot \
  --quay-pass "YOUR_TOKEN" \
  --namespace netbox \
  --storage-class nfs-csidriver3
```

The script performs all steps above: pulls the image, pushes it to your registry, generates credentials, creates all resources, waits for readiness, and prints the admin URL and credentials.
