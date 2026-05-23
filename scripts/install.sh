#!/usr/bin/env bash
# =============================================================================
# NetBox 3.4.1 — OpenShift One-Click Install
# =============================================================================
# Deploys NetBox 3.4.1 with PostgreSQL, Redis (sessions + cache) and a TLS
# route on an OpenShift cluster.  All manifests are generated inline so no
# external files are needed — just point the script at your registry and go.
#
# Usage:
#   ./scripts/install.sh [OPTIONS]
#
# Options:
#   --registry IMAGE            Full image path (default: auto from env)
#   --namespace NAME            OpenShift namespace  (default: netbox)
#   --admin-password PASS       Admin password       (default: random)
#   --storage-class CLASS       PVC storage class    (default: auto-detect)
#   --pull-secret NAME          ImagePullSecret name (default: create new)
#   --pull-secret-server URL    Registry server for pull secret
#   --pull-secret-user USER     Registry user for pull secret
#   --pull-secret-pass PASS     Registry password for pull secret
#   --dry-run                   Generate manifests only, do not apply
#   --help                      Show this help
#
# Prerequisites:
#   - oc CLI authenticated to your OpenShift cluster
#   - A container image of NetBox 3.4.1 in your registry
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
NAMESPACE="netbox"
NETBOX_IMAGE=""
ADMIN_PASSWORD=""
STORAGE_CLASS="nfs-csidriver3"
PULL_SECRET_NAME="netbox-image-pull-secret"
PULL_SECRET_SERVER=""
PULL_SECRET_USER=""
PULL_SECRET_PASS=""
DRY_RUN=false
GENERATE_PULL_SECRET=false

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    sed -n '2,/^# Usage/ p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)         NETBOX_IMAGE="$2";        shift 2 ;;
        --namespace)        NAMESPACE="$2";           shift 2 ;;
        --admin-password)   ADMIN_PASSWORD="$2";      shift 2 ;;
        --storage-class)    STORAGE_CLASS="$2";       shift 2 ;;
        --pull-secret)      PULL_SECRET_NAME="$2";    shift 2 ;;
        --pull-secret-server) PULL_SECRET_SERVER="$2"; shift 2 ;;
        --pull-secret-user) PULL_SECRET_USER="$2";    shift 2 ;;
        --pull-secret-pass) PULL_SECRET_PASS="$2";    shift 2 ;;
        --dry-run)          DRY_RUN=true;             shift   ;;
        --help)             usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$NETBOX_IMAGE" ]]; then
    echo "ERROR: --registry is required."
    echo "  Example: --registry quay.io/myorg/netbox:3.4.1"
    exit 1
fi

if ! command -v oc &>/dev/null; then
    echo "ERROR: 'oc' CLI not found. Install or authenticate first."
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
banner() { echo ""; echo "═══════════════════════════════════════════════════════════"; echo "  $1"; echo "═══════════════════════════════════════════════════════════"; }
step()   { echo ""; echo "▶ $1"; }

# ── Step 0: Generate credentials ─────────────────────────────────────────────
step "Generating credentials"

DB_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
REDIS_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
REDIS_CACHE_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(64))")

if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
fi

echo "  DB password    : $(echo "$DB_PASSWORD" | head -c 16)…"
echo "  Redis password : $(echo "$REDIS_PASSWORD" | head -c 16)…"
echo "  Redis cache pw : $(echo "$REDIS_CACHE_PASSWORD" | head -c 16)…"
echo "  Admin password : $ADMIN_PASSWORD"

# ── Auto-detect storage class (only if not explicitly set) ───────────────────
if [[ "$STORAGE_CLASS" == "auto" ]]; then
    step "Detecting storage class"
    STORAGE_CLASS=$(oc get sc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$STORAGE_CLASS" ]]; then
        echo "WARNING: Could not auto-detect storage class. Falling back to 'nfs-csidriver3'."
        STORAGE_CLASS="nfs-csidriver3"
    fi
    echo "  Storage class: $STORAGE_CLASS"
fi

# ── Step 1: Create namespace ─────────────────────────────────────────────────
step "Creating namespace: $NAMESPACE"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

echo "  ✓ Namespace ready"

# ── Step 2: Image pull secret ────────────────────────────────────────────────
if [[ -n "$PULL_SECRET_SERVER" && -n "$PULL_SECRET_USER" && -n "$PULL_SECRET_PASS" ]]; then
    step "Creating image pull secret"
    oc create secret docker-registry "$PULL_SECRET_NAME" \
        --docker-server="$PULL_SECRET_SERVER" \
        --docker-username="$PULL_SECRET_USER" \
        --docker-password="$PULL_SECRET_PASS" \
        --docker-email="install@netbox" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    echo "  ✓ Pull secret created"
elif [[ -n "$PULL_SECRET_SERVER" ]]; then
    echo "WARNING: --pull-secret-server provided without user/pass — skipping pull secret."
    echo "  Create it manually or re-run with --pull-secret-user and --pull-secret-pass."
fi

# ── Step 3: Secret ───────────────────────────────────────────────────────────
step "Creating Secret (netbox-env)"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: netbox-env
  namespace: $NAMESPACE
type: Opaque
stringData:
  DB_HOST: "netbox-postgres"
  DB_NAME: "netbox"
  DB_USER: "netbox"
  DB_PASSWORD: "$DB_PASSWORD"

  REDIS_HOST: "netbox-redis"
  REDIS_PASSWORD: "$REDIS_PASSWORD"

  REDIS_CACHE_HOST: "netbox-redis-cache"
  REDIS_CACHE_PASSWORD: "$REDIS_CACHE_PASSWORD"

  SECRET_KEY: "$SECRET_KEY"

  SKIP_SUPERUSER: "false"
  SUPERUSER_NAME: "admin"
  SUPERUSER_PASSWORD: "$ADMIN_PASSWORD"
  SUPERUSER_EMAIL: "admin@example.com"

  GRANIAN_WORKERS: "4"
  GRANIAN_BACKPRESSURE: "4"

  CORS_ORIGIN_ALLOW_ALL: "True"
EOF

echo "  ✓ Secret created"

# ── Restart pods to pick up new secret ────────────────────────────────────────
# If deployments already exist, rolling them ensures pods get fresh env vars.
# Without this, pods keep cached env from the old secret and DB passwords diverge.
step "Syncing deployments with new credentials"
for deploy in netbox-postgres netbox-redis netbox-redis-cache netbox; do
    if oc get deploy "$deploy" -n "$NAMESPACE" &>/dev/null; then
        echo "  Rolling $deploy…"
        oc rollout restart deploy/"$deploy" -n "$NAMESPACE" 2>/dev/null || true
    fi
done
echo "  ✓ Deployments synced"

# ── Step 4: ConfigMap ────────────────────────────────────────────────────────
step "Creating ConfigMap (netbox-config)"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: netbox-config
  namespace: $NAMESPACE
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

echo "  ✓ ConfigMap created"

# ── Step 5: PostgreSQL ───────────────────────────────────────────────────────
step "Deploying PostgreSQL 18"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: netbox-postgres
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
            seccompProfile:
              type: RuntimeDefault
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
EOF

echo "  ✓ PostgreSQL deployed"

# ── Step 6: Redis (sessions) ─────────────────────────────────────────────────
step "Deploying Redis (sessions)"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: netbox-redis
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-redis-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
EOF

echo "  ✓ Redis (sessions) deployed"

# ── Step 7: Redis (cache) ────────────────────────────────────────────────────
step "Deploying Redis (cache)"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: netbox-redis-cache
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-redis-cache-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
EOF

echo "  ✓ Redis (cache) deployed"

# ── Step 8: NetBox app ───────────────────────────────────────────────────────
step "Deploying NetBox 3.4.1"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: netbox
  namespace: $NAMESPACE
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
  namespace: $NAMESPACE
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
        - name: $PULL_SECRET_NAME
      containers:
        - name: netbox
          image: $NETBOX_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
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
            seccompProfile:
              type: RuntimeDefault
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
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-media-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-reports-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: netbox-scripts-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  $(if [[ -n "$STORAGE_CLASS" ]]; then echo "storageClassName: $STORAGE_CLASS"; fi)
EOF

echo "  ✓ NetBox deployed"

# ── Step 9: Route ────────────────────────────────────────────────────────────
step "Creating Route (TLS edge)"

cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: netbox
  namespace: $NAMESPACE
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

echo "  ✓ Route created"

# ── Step 10: Wait for dependencies ───────────────────────────────────────────
step "Waiting for PostgreSQL to be ready"
oc wait --for=condition=ready pod -l app=netbox-postgres \
    -n "$NAMESPACE" --timeout=180s 2>&1 || {
    echo "  ✗ PostgreSQL not ready. Check logs:"
    oc logs -l app=netbox-postgres -n "$NAMESPACE" --tail=20 2>/dev/null
    exit 1
}
echo "  ✓ PostgreSQL ready"

step "Waiting for Redis (sessions) to be ready"
oc wait --for=condition=ready pod -l app=netbox-redis \
    -n "$NAMESPACE" --timeout=120s 2>&1 || {
    echo "  ✗ Redis (sessions) not ready"
    oc logs -l app=netbox-redis -n "$NAMESPACE" --tail=20 2>/dev/null
    exit 1
}
echo "  ✓ Redis (sessions) ready"

step "Waiting for Redis (cache) to be ready"
oc wait --for=condition=ready pod -l app=netbox-redis-cache \
    -n "$NAMESPACE" --timeout=120s 2>&1 || {
    echo "  ✗ Redis (cache) not ready"
    oc logs -l app=netbox-redis-cache -n "$NAMESPACE" --tail=20 2>/dev/null
    exit 1
}
echo "  ✓ Redis (cache) ready"

# ── Step 11: Wait for NetBox ─────────────────────────────────────────────────
step "Waiting for NetBox to start (up to 10 minutes for migrations + superuser)…"
oc wait --for=condition=ready pod -l app=netbox \
    -n "$NAMESPACE" --timeout=600s 2>&1 || {
    echo "  ✗ NetBox not ready. Check logs:"
    oc logs -l app=netbox -n "$NAMESPACE" -c netbox --tail=30 2>/dev/null
    oc logs -l app=netbox -n "$NAMESPACE" -c netbox-worker --tail=30 2>/dev/null
    echo ""
    echo "  If the worker sidecar failed, see the troubleshooting section in the README."
    exit 1
}
echo "  ✓ NetBox ready"

# ── Step 12: Post-install verification ───────────────────────────────────────
step "Verifying deployment"

# Get the route URL
ROUTE_URL=$(oc get route netbox -n "$NAMESPACE" -o jsonpath='{.spec.host}')

# Wait a moment for the route to propagate
sleep 3

# Health check
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$ROUTE_URL/login/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  ✓ HTTP health check passed (200 OK)"
else
    echo "  ⚠ HTTP health check returned $HTTP_CODE — the route may need a moment to propagate"
fi

# ── Final summary ────────────────────────────────────────────────────────────
banner "✅ DEPLOYMENT COMPLETE — NetBox 3.4.1 is running"

echo ""
echo "  📍 URL:         https://$ROUTE_URL"
echo "  👤 Username:    admin"
echo "  🔑 Password:    $ADMIN_PASSWORD"
echo ""
echo "  📦 Pods:"
oc get pods -n "$NAMESPACE" -o wide
echo ""
echo "  🗺️  Routes:"
oc get route -n "$NAMESPACE"
echo ""
echo "  💾 Persistent Volumes:"
oc get pvc -n "$NAMESPACE"
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  Save the admin password — it won't be shown again!"
echo "  To change it later, see the README troubleshooting section."
echo "───────────────────────────────────────────────────────────"
