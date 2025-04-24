random=$(echo $RANDOM | tr '[0-9]' '[a-z]')
export MY_LOCATION=switzerlandnorth
export MY_RESOURCE_GROUP_NAME=rg-lbn-airflow
export MY_IDENTITY_NAME=airflow-identity-123
export MY_ACR_REGISTRY=mydnsrandomname$(echo $random)
export MY_KEYVAULT_NAME=airflow-vault-$(echo $random)-kv
export MY_CLUSTER_NAME=apache-airflow-aks
export SERVICE_ACCOUNT_NAME=lbn-airflow
export SERVICE_ACCOUNT_NAMESPACE=lbn-airflow
export AKS_AIRFLOW_NAMESPACE=lbn-airflow
export AKS_AIRFLOW_CLUSTER_NAME=cluster-aks-airflow
export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME=airflowsasa$(echo $random)
export AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME=airflow-logs
export AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME=storage-account-credentials



# Create Resource Group
az group create --name $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --output table

#Create an identity to access secrets in Azure Key Vault
az identity create --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --output table
export MY_IDENTITY_NAME_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query id --output tsv)
export MY_IDENTITY_NAME_PRINCIPAL_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query principalId --output tsv)
export MY_IDENTITY_NAME_CLIENT_ID=$(az identity show --name $MY_IDENTITY_NAME --resource-group $MY_RESOURCE_GROUP_NAME --query clientId --output tsv)

# Create an Azure Key Vault instance
az keyvault create --name $MY_KEYVAULT_NAME --resource-group $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --enable-rbac-authorization false --output table
export KEYVAULTID=$(az keyvault show --name $MY_KEYVAULT_NAME --query "id" --output tsv)
export KEYVAULTURL=$(az keyvault show --name $MY_KEYVAULT_NAME --query "properties.vaultUri" --output tsv)


# Create an Azure Container Registry
az acr create --name ${MY_ACR_REGISTRY} --resource-group $MY_RESOURCE_GROUP_NAME --sku Premium --location $MY_LOCATION --admin-enabled true --output table
export MY_ACR_REGISTRY_ID=$(az acr show --name $MY_ACR_REGISTRY --resource-group $MY_RESOURCE_GROUP_NAME --query id --output tsv)

# Create an Azure storage account
az storage account create --name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --resource-group $MY_RESOURCE_GROUP_NAME --location $MY_LOCATION --sku Standard_ZRS --output table
export AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)
az storage container create --name $AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME --account-name $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME --output table --account-key $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY
az keyvault secret set --vault-name $MY_KEYVAULT_NAME --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME --value $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME
az keyvault secret set --vault-name $MY_KEYVAULT_NAME --name AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY --value $AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_KEY

# Create an AKS cluster
az aks create --location $MY_LOCATION --name $MY_CLUSTER_NAME --tier standard --resource-group $MY_RESOURCE_GROUP_NAME --network-plugin azure --node-vm-size Standard_DS4_v2 --node-count 1 --auto-upgrade-channel stable --node-os-upgrade-channel NodeImage --attach-acr ${MY_ACR_REGISTRY} --enable-oidc-issuer --enable-blob-driver --enable-workload-identity --zones 1 2 3 --generate-ssh-keys --output table

# Get the OIDC issuer URL
export OIDC_URL=$(az aks show --resource-group $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --query oidcIssuerProfile.issuerUrl --output tsv)

# Assign the AcrPull role to the kubelet identity
export KUBELET_IDENTITY=$(az aks show -g $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --output tsv --query identityProfile.kubeletidentity.objectId)
az role assignment create --assignee ${KUBELET_IDENTITY} --role "AcrPull" --scope ${MY_ACR_REGISTRY_ID} --output table

# Connect to AKS cluster
az aks get-credentials --resource-group $MY_RESOURCE_GROUP_NAME --name $MY_CLUSTER_NAME --overwrite-existing --output table

# Upload Apache Airflow images to container registery
az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:airflow-pgbouncer-2024.01.19-1.21.0 --image airflow:airflow-pgbouncer-2024.01.19-1.21.0
az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0 --image airflow:airflow-pgbouncer-exporter-2024.06.18-0.17.0
az acr import --name $MY_ACR_REGISTRY --source docker.io/bitnami/postgresql:16.1.0-debian-11-r15 --image postgresql:16.1.0-debian-11-r15
az acr import --name $MY_ACR_REGISTRY --source quay.io/prometheus/statsd-exporter:v0.26.1 --image statsd-exporter:v0.26.1 
az acr import --name $MY_ACR_REGISTRY --source docker.io/apache/airflow:2.9.3 --image airflow:2.9.3 
az acr import --name $MY_ACR_REGISTRY --source registry.k8s.io/git-sync/git-sync:v4.1.0 --image git-sync:v4.1.0

### DEPLOY AIRFLOW

# Configure workload identity
kubectl create namespace ${AKS_AIRFLOW_NAMESPACE} --dry-run=client --output yaml | kubectl apply -f -

#Create Service Account and configure workload identity
export TENANT_ID=$(az account show --query tenantId -o tsv)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${MY_IDENTITY_NAME_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${TENANT_ID}"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${AKS_AIRFLOW_NAMESPACE}"
EOF
>>

#Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
external-secrets/external-secrets \
--namespace ${AKS_AIRFLOW_NAMESPACE} \
--create-namespace \
--set installCRDs=true \
--wait

# Create Secrets
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: azure-store
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  provider:
    # provider type: azure keyvault
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "${KEYVAULTURL}"
      serviceAccountRef:
        name: ${SERVICE_ACCOUNT_NAME}
EOF

# Create and ExternalSecret Resource
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: airflow-aks-azure-logs-secrets
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: azure-store

  target:
    name: ${AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME}
    creationPolicy: Owner

  data:
    # name of the SECRET in the Azure KV (no prefix is by default a SECRET)
    - secretKey: azurestorageaccountname
      remoteRef:
        key: AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-NAME
    - secretKey: azurestorageaccountkey
      remoteRef:
        key: AKS-AIRFLOW-LOGS-STORAGE-ACCOUNT-KEY
EOF

# Create Federated Credentials
az identity federated-credential create --name external-secret-operator --identity-name ${MY_IDENTITY_NAME} --resource-group ${MY_RESOURCE_GROUP_NAME} --issuer ${OIDC_URL} --subject system:serviceaccount:${AKS_AIRFLOW_NAMESPACE}:${SERVICE_ACCOUNT_NAME} --output table

# Give Permissions to the user assigne identity
az keyvault set-policy --name $MY_KEYVAULT_NAME --object-id $MY_IDENTITY_NAME_PRINCIPAL_ID --secret-permissions get --output table

# Create Volume for Apache Airflow logs
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-airflow-logs
  labels:
    type: local
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain # If set as "Delete" container would be removed after pvc deletion
  storageClassName: azureblob-fuse-premium
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    volumeHandle: airflow-logs-1
    volumeAttributes:
      resourceGroup: ${MY_RESOURCE_GROUP_NAME}
      storageAccount: ${AKS_AIRFLOW_LOGS_STORAGE_ACCOUNT_NAME}
      containerName: ${AKS_AIRFLOW_LOGS_STORAGE_CONTAINER_NAME}
    nodeStageSecretRef:
      name: ${AKS_AIRFLOW_LOGS_STORAGE_SECRET_NAME}
      namespace: ${AKS_AIRFLOW_NAMESPACE}
EOF

# Create persistent volume claim for apache airflow logs
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-airflow-logs
  namespace: ${AKS_AIRFLOW_NAMESPACE}
spec:
  storageClassName: azureblob-fuse-premium
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: pv-airflow-logs
EOF

# Deploy apache using helm
cat <<EOF> airflow_values.yaml

images:
  airflow:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    # Specifying digest takes precedence over tag.
    digest: ~
    pullPolicy: IfNotPresent
  # To avoid images with user code, you can turn this to 'true' and
  # all the 'run-airflow-migrations' and 'wait-for-airflow-migrations' containers/jobs
  # will use the images from 'defaultAirflowRepository:defaultAirflowTag' values
  # to run and wait for DB migrations .
  useDefaultImageForMigration: false
  # timeout (in seconds) for airflow-migrations to complete
  migrationsWaitTimeout: 60
  pod_template:
    # Note that `images.pod_template.repository` and `images.pod_template.tag` parameters
    # can be overridden in `config.kubernetes` section. So for these parameters to have effect
    # `config.kubernetes.worker_container_repository` and `config.kubernetes.worker_container_tag`
    # must be not set .
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    pullPolicy: IfNotPresent
  flower:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: 2.9.3
    pullPolicy: IfNotPresent
  statsd:
    repository: $MY_ACR_REGISTRY.azurecr.io/statsd-exporter
    tag: v0.26.1
    pullPolicy: IfNotPresent
  pgbouncer:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: airflow-pgbouncer-2024.01.19-1.21.0
    pullPolicy: IfNotPresent
  pgbouncerExporter:
    repository: $MY_ACR_REGISTRY.azurecr.io/airflow
    tag: airflow-pgbouncer-exporter-2024.06.18-0.17.0
    pullPolicy: IfNotPresent
  gitSync:
    repository: $MY_ACR_REGISTRY.azurecr.io/git-sync
    tag: v4.1.0
    pullPolicy: IfNotPresent


# Airflow executor
executor: "KubernetesExecutor"

# Environment variables for all airflow containers
env:
  - name: ENVIRONMENT
    value: dev

extraEnv: |
  - name: AIRFLOW__CORE__DEFAULT_TIMEZONE
    value: 'America/New_York'

# Configuration for postgresql subchart
# Not recommended for production! Instead, spin up your own Postgresql server and use the `data` attribute in this
# yaml file.
postgresql:
  enabled: true

# Enable pgbouncer. See https://airflow.apache.org/docs/helm-chart/stable/production-guide.html#pgbouncer
pgbouncer:
  enabled: true

dags:
  gitSync:
    enabled: true
    repo: https://github.com/donhighmsft/airflowexamples.git
    branch: main
    rev: HEAD
    depth: 1
    maxFailures: 0
    subPath: "dags"
    # sshKeySecret: airflow-git-ssh-secret
    # knownHosts: |
    #   github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=

logs:
  persistence:
    enabled: true
    existingClaim: pvc-airflow-logs
    storageClassName: azureblob-fuse-premium

# We disable the log groomer sidecar because we use Azure Blob Storage for logs, with lifecyle policy set.
triggerer:
  logGroomerSidecar:
    enabled: false

scheduler:
  logGroomerSidecar:
    enabled: false

workers:
  logGroomerSidecar:
    enabled: false

EOF
