#!/usr/bin/env bash
# codebuild-deploy.sh — Build images via AWS CodeBuild, then deploy to EKS
# No local Docker login required.
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_PROFILE="${AWS_PROFILE:-umatrenddemo}"
AWS_REGION_ECR="ap-southeast-2"
AWS_REGION_EKS="us-east-1"
AWS_REGION_CB="ap-southeast-2"     # CodeBuild runs in same region as ECR
ACCOUNT_ID="834797984653"
CLUSTER_NAME="automode-cluster"
KUBE_CONTEXT="arn:aws:eks:${AWS_REGION_EKS}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
APP="ai-doc-analyzer"
CB_PROJECT_NAME="ai-doc-analyzer-build"
GITHUB_REPO="https://github.com/uragupathy-trend/ai-doc-analyzer"
CB_ROLE_NAME="codebuild-ai-doc-analyzer-role"

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

# ── Pre-flight ────────────────────────────────────────────────────────────────
info "Pre-flight checks"
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
[[ -n "$V1_API_KEY" ]] || die "V1_API_KEY is empty in .env"
ok "V1_API_KEY present"

AI_GUARD_ENDPOINT="$(grep '^AI_GUARD_ENDPOINT=' "$ENV_FILE" | cut -d= -f2-)"
AI_GUARD_ENDPOINT="${AI_GUARD_ENDPOINT:-https://api.au.xdr.trendmicro.com/v3.0/aiSecurity/applyGuardrails}"

# ── IAM Role for Service Account (IRSA) ──────────────────────────────────────
info "Setting up IRSA (Bedrock access for pods)"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:default:${SA_NAME}",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

if aws iam get-role --profile "$AWS_PROFILE" --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  aws iam update-assume-role-policy --profile "$AWS_PROFILE" \
    --role-name "$IAM_ROLE_NAME" --policy-document "$TRUST_POLICY" &>/dev/null
  ok "IRSA IAM role exists: ${IAM_ROLE_NAME}"
else
  aws iam create-role --profile "$AWS_PROFILE" \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "ai-doc-analyzer pods → Bedrock" \
    --output text --query 'Role.RoleName' &>/dev/null
  ok "IRSA IAM role created: ${IAM_ROLE_NAME}"
fi

aws iam put-role-policy --profile "$AWS_PROFILE" \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "BedrockInvokePolicy" \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
      "Resource":[
        "arn:aws:bedrock:ap-southeast-2::foundation-model/*",
        "arn:aws:bedrock:ap-southeast-2:'"${ACCOUNT_ID}"':inference-profile/*"
      ]
    }]
  }' &>/dev/null
ok "Bedrock inline policy attached"

IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

# ── Kubernetes ServiceAccount ─────────────────────────────────────────────────
info "Ensuring Kubernetes ServiceAccount with IRSA annotation"
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

# ── CodeBuild IAM role ────────────────────────────────────────────────────────
info "Ensuring CodeBuild IAM role"

CB_TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codebuild.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

if aws iam get-role --profile "$AWS_PROFILE" --role-name "$CB_ROLE_NAME" &>/dev/null; then
  ok "CodeBuild IAM role exists: ${CB_ROLE_NAME}"
else
  aws iam create-role --profile "$AWS_PROFILE" \
    --role-name "$CB_ROLE_NAME" \
    --assume-role-policy-document "$CB_TRUST" \
    --output text --query 'Role.RoleName' &>/dev/null
  ok "CodeBuild IAM role created: ${CB_ROLE_NAME}"
fi

# Attach policies needed for CodeBuild: ECR push + CloudWatch logs
aws iam attach-role-policy --profile "$AWS_PROFILE" \
  --role-name "$CB_ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser" 2>/dev/null || true

aws iam put-role-policy --profile "$AWS_PROFILE" \
  --role-name "$CB_ROLE_NAME" \
  --policy-name "CloudWatchLogsPolicy" \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource":"*"
    }]
  }' &>/dev/null
ok "CodeBuild policies attached"

CB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CB_ROLE_NAME}"

# ── Create or update CodeBuild project ───────────────────────────────────────
info "Ensuring CodeBuild project: ${CB_PROJECT_NAME}"

CB_PROJECT_JSON=$(cat <<EOF
{
  "name": "${CB_PROJECT_NAME}",
  "source": {
    "type": "GITHUB",
    "location": "${GITHUB_REPO}",
    "buildspec": "buildspec.yml",
    "gitCloneDepth": 1
  },
  "artifacts": {"type": "NO_ARTIFACTS"},
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_MEDIUM",
    "privilegedMode": true
  },
  "serviceRole": "${CB_ROLE_ARN}",
  "logsConfig": {
    "cloudWatchLogs": {"status": "ENABLED", "groupName": "/aws/codebuild/${CB_PROJECT_NAME}"}
  }
}
EOF
)

if aws codebuild batch-get-projects --profile "$AWS_PROFILE" --region "$AWS_REGION_CB" \
    --names "$CB_PROJECT_NAME" --query 'projects[0].name' --output text 2>/dev/null | grep -q "$CB_PROJECT_NAME"; then
  aws codebuild update-project --profile "$AWS_PROFILE" --region "$AWS_REGION_CB" \
    --cli-input-json "$CB_PROJECT_JSON" --output text --query 'project.name' &>/dev/null
  ok "CodeBuild project updated"
else
  # Brief pause to let IAM role propagate
  echo "   Waiting for IAM role to propagate (10s)..."
  sleep 10
  aws codebuild create-project --profile "$AWS_PROFILE" --region "$AWS_REGION_CB" \
    --cli-input-json "$CB_PROJECT_JSON" --output text --query 'project.name' &>/dev/null
  ok "CodeBuild project created"
fi

# ── Trigger build ─────────────────────────────────────────────────────────────
info "Starting CodeBuild — building and pushing images to ECR"
BUILD_ID=$(aws codebuild start-build \
  --profile "$AWS_PROFILE" --region "$AWS_REGION_CB" \
  --project-name "$CB_PROJECT_NAME" \
  --query 'build.id' --output text)
ok "Build started: ${BUILD_ID}"
echo "   Logs: https://${AWS_REGION_CB}.console.aws.amazon.com/codesuite/codebuild/${ACCOUNT_ID}/projects/${CB_PROJECT_NAME}/build/${BUILD_ID//:/\%3A}/log"

# ── Poll until complete ───────────────────────────────────────────────────────
info "Waiting for CodeBuild to finish (this takes ~5-8 min)..."
ELAPSED=0
INTERVAL=30
TIMEOUT=900  # 15 min max
while true; do
  STATUS=$(aws codebuild batch-get-builds \
    --profile "$AWS_PROFILE" --region "$AWS_REGION_CB" \
    --ids "$BUILD_ID" \
    --query 'builds[0].buildStatus' --output text)
  case "$STATUS" in
    SUCCEEDED)
      ok "CodeBuild SUCCEEDED — all images pushed to ECR"
      break
      ;;
    FAILED|FAULT|TIMED_OUT|STOPPED)
      die "CodeBuild ${STATUS}. Check logs at the URL above."
      ;;
    IN_PROGRESS)
      echo "   ... still building (${ELAPSED}s elapsed)"
      ;;
  esac
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
  [[ $ELAPSED -ge $TIMEOUT ]] && die "Timed out waiting for CodeBuild after ${TIMEOUT}s"
done

# ── Deploy to EKS ─────────────────────────────────────────────────────────────
info "Deploying to EKS: ${CLUSTER_NAME}"
K8S_DIR="${SCRIPT_DIR}/k8s"

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

for manifest in api-deployment.yaml worker-deployment.yaml frontend-deployment.yaml; do
  info "Applying ${manifest}"
  sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
      -e "s/SA_NAME/${SA_NAME}/g" \
      "${K8S_DIR}/${manifest}" \
    | kubectl --context "$KUBE_CONTEXT" apply -f -
  ok "${manifest} applied"
done

# ── Wait for rollout ──────────────────────────────────────────────────────────
info "Waiting for rollouts (up to 3 min each)"
for deploy in ai-doc-analyzer-api ai-doc-analyzer-worker ai-doc-analyzer-frontend; do
  kubectl --context "$KUBE_CONTEXT" rollout status deployment/"$deploy" \
    --timeout=180s || die "Rollout failed for ${deploy} — run: kubectl logs -l app=${deploy}"
  ok "${deploy} ready"
done

# ── Print endpoints ───────────────────────────────────────────────────────────
info "Deployment complete"
echo ""
kubectl --context "$KUBE_CONTEXT" get svc ai-doc-analyzer-frontend \
  -o custom-columns='SERVICE:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].hostname,PORT:.spec.ports[0].port'
echo ""
LB_HOST=$(kubectl --context "$KUBE_CONTEXT" get svc ai-doc-analyzer-frontend \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -z "$LB_HOST" ]]; then
  echo "   LoadBalancer hostname still provisioning — check in 1-2 min:"
  echo "   kubectl get svc ai-doc-analyzer-frontend --context ${KUBE_CONTEXT}"
else
  echo "   Frontend UI : http://${LB_HOST}"
  echo "   API health  : http://${LB_HOST}/api/health"
fi
