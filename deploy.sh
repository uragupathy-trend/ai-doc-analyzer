#!/usr/bin/env bash
# deploy.sh — Build, push to ECR, and deploy ai-doc-analyzer to EKS automode-cluster
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-umatrenddemo}"
AWS_REGION_ECR="ap-southeast-2"
AWS_REGION_EKS="us-east-1"
ACCOUNT_ID="834797984653"
CLUSTER_NAME="automode-cluster"
KUBE_CONTEXT="arn:aws:eks:${AWS_REGION_EKS}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION_ECR}.amazonaws.com"
APP="ai-doc-analyzer"
TAG="${1:-latest}"

OIDC_ISSUER="oidc.eks.${AWS_REGION_EKS}.amazonaws.com/id/F160826591E30AF6E929C30860D6C496"
SA_NAME="ai-doc-analyzer-sa"
IAM_ROLE_NAME="ai-doc-analyzer-bedrock-role"

export PATH=$PATH:/opt/homebrew/bin

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo ""; echo "▶  $*"; }
ok()    { echo "   ✅ $*"; }
die()   { echo ""; echo "❌ $*" >&2; exit 1; }
require() { command -v "$1" &>/dev/null || die "Missing required tool: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pre-flight ─────────────────────────────────────────────────────────────────
info "Pre-flight checks"
require docker
require aws
require kubectl

aws sts get-caller-identity --profile "$AWS_PROFILE" --output text \
  --query 'Account' &>/dev/null || die "AWS profile '${AWS_PROFILE}' not authenticated"
ok "AWS profile: ${AWS_PROFILE} (account ${ACCOUNT_ID})"

kubectl --context "$KUBE_CONTEXT" get nodes &>/dev/null \
  || die "Cannot reach EKS cluster. Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION_EKS} --profile ${AWS_PROFILE}"
ok "EKS cluster reachable: ${CLUSTER_NAME}"

ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}"
V1_API_KEY="$(grep '^V1_API_KEY=' "$ENV_FILE" | cut -d= -f2-)"
[[ -n "$V1_API_KEY" ]] || die "V1_API_KEY is empty in .env — add your Vision One API key"
ok "V1_API_KEY present"

AI_GUARD_ENDPOINT="$(grep '^AI_GUARD_ENDPOINT=' "$ENV_FILE" | cut -d= -f2-)"
AI_GUARD_ENDPOINT="${AI_GUARD_ENDPOINT:-https://api.au.xdr.trendmicro.com/v3.0/aiSecurity/applyGuardrails}"

# ── IAM Role for Service Account (IRSA) ─────────────────────────────────────
info "Setting up IAM role for Bedrock access (IRSA)"

# Create trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER}:sub": "system:serviceaccount:default:${SA_NAME}",
          "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

# Create or update the IAM role
if aws iam get-role --profile "$AWS_PROFILE" --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  aws iam update-assume-role-policy --profile "$AWS_PROFILE" \
    --role-name "$IAM_ROLE_NAME" \
    --policy-document "$TRUST_POLICY" &>/dev/null
  ok "IAM role updated: ${IAM_ROLE_NAME}"
else
  aws iam create-role --profile "$AWS_PROFILE" \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Allows ai-doc-analyzer pods to call AWS Bedrock" \
    --output text --query 'Role.RoleName' &>/dev/null
  ok "IAM role created: ${IAM_ROLE_NAME}"
fi

# Attach Bedrock inline policy
BEDROCK_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:ap-southeast-2::foundation-model/*",
        "arn:aws:bedrock:ap-southeast-2:${ACCOUNT_ID}:inference-profile/*"
      ]
    }
  ]
}
EOF
)

aws iam put-role-policy --profile "$AWS_PROFILE" \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "BedrockInvokePolicy" \
  --policy-document "$BEDROCK_POLICY" &>/dev/null
ok "Bedrock IAM policy attached"

IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

# ── Kubernetes Service Account ────────────────────────────────────────────────
info "Creating Kubernetes ServiceAccount with IRSA annotation"
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: "${IAM_ROLE_ARN}"
EOF
ok "ServiceAccount ${SA_NAME} ready"

# ── ECR login ─────────────────────────────────────────────────────────────────
info "Logging into ECR (${AWS_REGION_ECR})"
aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION_ECR" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
ok "ECR login successful"

# ── Create ECR repos if missing ───────────────────────────────────────────────
info "Ensuring ECR repositories exist"
for repo in api worker frontend; do
  aws ecr describe-repositories \
    --profile "$AWS_PROFILE" --region "$AWS_REGION_ECR" \
    --repository-names "${APP}/${repo}" &>/dev/null \
  || aws ecr create-repository \
      --profile "$AWS_PROFILE" --region "$AWS_REGION_ECR" \
      --repository-name "${APP}/${repo}" \
      --image-scanning-configuration scanOnPush=true \
      --output text --query 'repository.repositoryUri' &>/dev/null
  ok "ECR repo: ${APP}/${repo}"
done

# ── Build & push images ───────────────────────────────────────────────────────
build_push() {
  local name="$1"
  local context="$2"
  local image="${ECR_REGISTRY}/${APP}/${name}:${TAG}"
  info "Building ${name} image (linux/amd64)"
  docker build --platform linux/amd64 -t "$image" "$context"
  info "Pushing ${name} → ECR"
  docker push "$image"
  if [[ "$TAG" != "latest" ]]; then
    docker tag "$image" "${ECR_REGISTRY}/${APP}/${name}:latest"
    docker push "${ECR_REGISTRY}/${APP}/${name}:latest"
  fi
  ok "Pushed ${name}:${TAG}"
}

build_push api      "${SCRIPT_DIR}/api"
build_push worker   "${SCRIPT_DIR}/worker"
build_push frontend "${SCRIPT_DIR}/frontend"

# ── Deploy to EKS ─────────────────────────────────────────────────────────────
info "Deploying to EKS: ${CLUSTER_NAME}"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Secret with real values from .env
info "Creating/updating Kubernetes Secret"
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ai-doc-analyzer-secrets
  namespace: default
type: Opaque
stringData:
  V1_API_KEY: "${V1_API_KEY}"
  AI_GUARD_ENDPOINT: "${AI_GUARD_ENDPOINT}"
  AI_GUARD_APP_NAME: "ai-doc-analyzer"
EOF
ok "Secret applied"

# Apply manifests with ACCOUNT_ID and SERVICE_ACCOUNT substituted
for manifest in api-deployment.yaml worker-deployment.yaml frontend-deployment.yaml; do
  info "Applying ${manifest}"
  sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
      -e "s/SA_NAME/${SA_NAME}/g" \
      "${K8S_DIR}/${manifest}" \
    | kubectl --context "$KUBE_CONTEXT" apply -f -
  ok "${manifest} applied"
done

# ── Wait for rollout ──────────────────────────────────────────────────────────
info "Waiting for rollouts to complete (up to 3 min each)"
for deploy in ai-doc-analyzer-api ai-doc-analyzer-worker ai-doc-analyzer-frontend; do
  kubectl --context "$KUBE_CONTEXT" rollout status deployment/"$deploy" \
    --timeout=180s || die "Rollout failed for ${deploy} — run: kubectl logs -l app=${deploy} to debug"
  ok "${deploy} ready"
done

# ── Print endpoints ───────────────────────────────────────────────────────────
info "Deployment complete"
echo ""
kubectl --context "$KUBE_CONTEXT" get svc ai-doc-analyzer-frontend \
  -o custom-columns='SERVICE:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].hostname,PORT:.spec.ports[0].port'
echo ""
LB_HOST=$(kubectl --context "$KUBE_CONTEXT" get svc ai-doc-analyzer-frontend \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "<pending>")
if [[ "$LB_HOST" == "<pending>" || -z "$LB_HOST" ]]; then
  echo "   LoadBalancer hostname is still provisioning — check again in 1-2 min:"
  echo "   kubectl get svc ai-doc-analyzer-frontend --context ${KUBE_CONTEXT}"
else
  echo "   Frontend UI : http://${LB_HOST}"
  echo "   API health  : http://${LB_HOST}/api/health"
fi
