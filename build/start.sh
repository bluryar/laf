echo "DOMAIN: $DOMAIN"

# check $DOMAIN is available
if ! host $DOMAIN; then
    echo "Domain $DOMAIN is not available"
    exit 1
fi

# *************** Environment Variables ************** #

## envs - global
EXTERNAL_HTTP_SCHEMA=${EXTERNAL_HTTP_SCHEMA:-https}
INTERNAL_HTTP_SCHEMA=${INTERNAL_HTTP_SCHEMA:-http}

NAMESPACE=${NAMESPACE:-laf-system}
PASSWD_OR_SECRET=$(tr -cd 'a-z0-9' </dev/urandom | head -c32)

ENABLE_MONITOR=${ENABLE_MONITOR:-true}
TLS_CRT_PATH=${TLS_CRT_PATH:-laf.example.com}
TLS_KEY_PATH=${TLS_KEY_PATH:-laf.example.com}
ENABLE_TLS=${ENABLE_TLS:-false}
TLS_SECRET_NAME=${TLS_SECRET_NAME:-laf-wildcard-secret}
# *************** Deployments **************** #

## 0. create namespace
kubectl create namespace ${NAMESPACE} || true

# 添加判断 ENABLE_TLS
if [ "${ENABLE_TLS}" = "true" ]; then
    if [ -n "${TLS_CRT_PATH}" ] && [ -n "${TLS_KEY_PATH}" ]; then
        # Convert TLS certificate and key to base64
        tls_crt_base64=$(cat $TLS_CRT_PATH | base64 | tr -d '\n')
        tls_key_base64=$(cat $TLS_KEY_PATH | base64 | tr -d '\n')
  
        # Define YAML content for TLS secret
        tls_secret_config="
  apiVersion: v1
  kind: Secret
  metadata:
    name: ${TLS_SECRET_NAME}
    namespace: ${NAMESPACE}
  type: kubernetes.io/tls
  data:
    tls.crt: $tls_crt_base64
    tls.key: $tls_key_base64
    "
    echo "$tls_secret_config"
    echo "$tls_secret_config" | kubectl apply -n ${NAMESPACE} -f -
    else
      echo "ERROR: TLS is enabled but TLS_CRT_PATH and/or TLS_KEY_PATH are not set"
      exit 1
    fi
fi
## 1. install mongodb
set -e
set -x

sed "s/\$CAPACITY/${DB_PV_SIZE:-5Gi}/g" mongodb.yaml | kubectl apply -n ${NAMESPACE} -f -
kubectl wait --for=condition=Ready --timeout=120s cluster.apps.kubeblocks.io/mongodb -n ${NAMESPACE}

DB_USERNAME=$(kubectl get secret -n ${NAMESPACE} mongodb-conn-credential -ojsonpath='{.data.username}' | base64 -d)
DB_PASSWORD=$(kubectl get secret -n ${NAMESPACE} mongodb-conn-credential -ojsonpath='{.data.password}' | base64 -d)
DB_ENDPOINT=$(kubectl get secret -n ${NAMESPACE} mongodb-conn-credential -ojsonpath='{.data.headlessEndpoint}' | base64 -d)
DATABASE_URL="mongodb://${DB_USERNAME}:${DB_PASSWORD}@${DB_ENDPOINT}/sys_db?authSource=admin&replicaSet=mongodb-mongodb&w=majority"

## 2. install prometheus
PROMETHEUS_URL=http://prometheus-operated.${NAMESPACE}.svc.cluster.local:9090
if [ "$ENABLE_MONITOR" = "true" ]; then
    sed -e "s/\$NAMESPACE/$NAMESPACE/g" \
        -e "s/\$PROMETHEUS_PV_SIZE/${PROMETHEUS_PV_SIZE:-20Gi}/g" \
        prometheus-helm.yaml >prometheus-helm-with-values.yaml

    helm install prometheus --version 48.3.3 -n ${NAMESPACE} \
        -f ./prometheus-helm-with-values.yaml \
        ./charts/kube-prometheus-stack
fi

## 3. install minio
MINIO_ROOT_ACCESS_KEY=minio-root-user
MINIO_ROOT_SECRET_KEY=$PASSWD_OR_SECRET
MINIO_DOMAIN=oss.${DOMAIN}
MINIO_EXTERNAL_ENDPOINT="${EXTERNAL_HTTP_SCHEMA}://${MINIO_DOMAIN}"
MINIO_INTERNAL_ENDPOINT="${INTERNAL_HTTP_SCHEMA}://minio.${NAMESPACE}.svc.cluster.local:9000"

helm install minio -n ${NAMESPACE} \
    --set rootUser=${MINIO_ROOT_ACCESS_KEY} \
    --set rootPassword=${MINIO_ROOT_SECRET_KEY} \
    --set persistence.size=${OSS_PV_SIZE:-3Gi} \
    --set domain=${MINIO_DOMAIN} \
    --set consoleHost=minio.${DOMAIN} \
    $([ "$ENABLE_TLS" = "true" ] && echo "--set secretName=${TLS_SECRET_NAME}") \
    --set metrics.serviceMonitor.enabled=${ENABLE_MONITOR} \
    --set metrics.serviceMonitor.additionalLabels.release=prometheus \
    --set metrics.serviceMonitor.additionalLabels.namespace=${NAMESPACE} \
    ./charts/minio

## 4. install laf-server
SERVER_JWT_SECRET=$PASSWD_OR_SECRET
RUNTIME_EXPORTER_SECRET=$PASSWD_OR_SECRET
helm install server -n ${NAMESPACE} \
    --set databaseUrl=${DATABASE_URL} \
    --set jwt.secret=${SERVER_JWT_SECRET} \
    --set apiServerHost=api.${DOMAIN} \
    --set apiServerUrl=${EXTERNAL_HTTP_SCHEMA}://api.${DOMAIN} \
    --set siteName=${DOMAIN} \
    $([ "$ENABLE_TLS" = "true" ] && echo "--set secretName=${TLS_SECRET_NAME}") \
    --set default_region.fixed_namespace=${NAMESPACE} \
    --set default_region.database_url=${DATABASE_URL} \
    --set default_region.minio_domain=${MINIO_DOMAIN} \
    --set default_region.minio_external_endpoint=${MINIO_EXTERNAL_ENDPOINT} \
    --set default_region.minio_internal_endpoint=${MINIO_INTERNAL_ENDPOINT} \
    --set default_region.minio_root_access_key=${MINIO_ROOT_ACCESS_KEY} \
    --set default_region.minio_root_secret_key=${MINIO_ROOT_SECRET_KEY} \
    --set default_region.runtime_domain=${DOMAIN} \
    --set default_region.website_domain=${DOMAIN} \
    $([ "$ENABLE_TLS" = "true" ] && echo "--set default_region.tls.enabled=true") \
    $([ "$ENABLE_TLS" = "true" ] && echo "--set default_region.tls.wildcard_certificate_secret_name=${TLS_SECRET_NAME}") \
    $([ "$ENABLE_TLS" = "false" ] && echo "--set default_region.tls.enabled=false") \
    $([ "$ENABLE_MONITOR" = "true" ] && echo "--set default_region.runtime_exporter_secret=${RUNTIME_EXPORTER_SECRET}") \
    $([ "$ENABLE_MONITOR" = "true" ] && echo "--set default_region.prometheus_url=${PROMETHEUS_URL}") \
    ./charts/laf-server

## 5. install laf-web
helm install web -n ${NAMESPACE} \
    $([ "$ENABLE_TLS" = "true" ] && echo "--set secretName=${TLS_SECRET_NAME}") \
    --set domain=${DOMAIN} \
    ./charts/laf-web
