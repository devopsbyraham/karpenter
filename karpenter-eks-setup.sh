#!/usr/bin/env bash
#
# karpenter-eks-setup.sh
# ----------------------------------------------------------------------------
# End-to-end Karpenter (v1.15.x, karpenter.sh/v1 API) installer for an
# EXISTING Amazon EKS cluster.
#
# What it does (each step is idempotent, so re-running is always safe):
#   1. Pre-flight: tools, AWS identity, cluster state/version, kubectl access,
#      node capacity, leftovers from earlier failed attempts.
#   2. Deploys the official Karpenter CloudFormation stack
#      (node role, 6 controller IAM policies, SQS interruption queue,
#      EventBridge rules).
#   3. Tags subnets + cluster security group with karpenter.sh/discovery.
#   4. Lets Karpenter-launched nodes join the cluster (EKS access entry,
#      or aws-auth mapping on CONFIG_MAP-only clusters).
#   5. Creates the controller IAM role and links it to the "karpenter"
#      service account (EKS Pod Identity by default, or IRSA).
#   6. Installs the Karpenter Helm chart.
#   7. Creates a default NodePool + EC2NodeClass.
#   8. Verifies: EC2NodeClass Ready, then launches a real test node and
#      removes it again.
#
# Usage:
#   CLUSTER_NAME=my-cluster AWS_REGION=ap-south-1 ./karpenter-eks-setup.sh
#   ./karpenter-eks-setup.sh --cluster my-cluster --region ap-south-1 --dry-run
#
# Run with DRY_RUN=true (or --dry-run) first: it performs every read-only check
# and PRINTS every change instead of making it.
# ----------------------------------------------------------------------------
set -Eeuo pipefail

###############################################################################
# Configuration (override with environment variables)
###############################################################################
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
PRINT_POLICY="${PRINT_POLICY:-false}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.15.1}"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-kube-system}"
AUTH_METHOD="${AUTH_METHOD:-pod-identity}"        # pod-identity | irsa
SUBNET_IDS="${SUBNET_IDS:-}"                      # comma list; default = private subnets of the cluster
ENABLE_ZONAL_SHIFT="${ENABLE_ZONAL_SHIFT:-false}"
NODEPOOL_NAME="${NODEPOOL_NAME:-default}"
NODECLASS_NAME="${NODECLASS_NAME:-default}"
CAPACITY_TYPES="${CAPACITY_TYPES:-on-demand}"     # on-demand | spot | on-demand,spot
NODE_ARCH="${NODE_ARCH:-amd64}"                   # amd64 | arm64 | amd64,arm64
INSTANCE_CATEGORIES="${INSTANCE_CATEGORIES:-c,m,r}"
CPU_LIMIT="${CPU_LIMIT:-100}"                     # max total vCPU the NodePool may create
CONTROLLER_CPU="${CONTROLLER_CPU:-1}"
CONTROLLER_MEMORY="${CONTROLLER_MEMORY:-1Gi}"
REPLICAS="${REPLICAS:-}"                          # default: 2 if >=2 regular nodes, else 1
SMOKE_TEST="${SMOKE_TEST:-true}"
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
FORCE_CLEANUP="${FORCE_CLEANUP:-false}"           # allow script to delete failed stack / detach legacy policy
AUTH_MODE_UPGRADE="${AUTH_MODE_UPGRADE:-false}"   # allow CONFIG_MAP -> API_AND_CONFIG_MAP (one-way)
SKIP_VERSION_CHECK="${SKIP_VERSION_CHECK:-false}"
CFN_TEMPLATE_FILE="${CFN_TEMPLATE_FILE:-}"        # use a local copy instead of downloading
IAM_SETTLE_SECONDS="${IAM_SETTLE_SECONDS:-10}"    # wait after creating the IAM role (eventual consistency)
LOG_SETTLE_SECONDS="${LOG_SETTLE_SECONDS:-20}"    # wait before scanning controller logs

###############################################################################
# Argument parsing
###############################################################################
usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)  CLUSTER_NAME="${2:?--cluster needs a value}"; shift 2 ;;
    --region)   AWS_REGION="${2:?--region needs a value}"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --print-policy) PRINT_POLICY=true; shift ;;
    --yes|-y)   ASSUME_YES=true; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

###############################################################################
# Helpers
###############################################################################
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi
log()  { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
# changed MSG : confirmation for a state-changing step ("would ..." in dry-run mode)
changed() {   # changed "<past tense>" "<what would happen>"
  if [[ "$DRY_RUN" == "true" ]]; then printf '    %s→ would: %s%s\n' "$C_YELLOW" "$2" "$C_OFF"; else ok "$1"; fi
}
warn() { printf '    %s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '\n%s✘ ERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
SMOKE_DEPLOYED=false

cleanup() {
  if [[ "$SMOKE_DEPLOYED" == "true" ]]; then
    kubectl delete deployment karpenter-smoke-test -n default --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
on_error() {
  local code=$? line=$1
  printf '\n%s✘ Failed%s at script line %s (exit %s): %s\n' "$C_RED" "$C_OFF" "$line" "$code" "$BASH_COMMAND" >&2
  printf '  Nothing is left half-configured that a re-run cannot fix: fix the cause above and run the script again.\n' >&2
}
trap cleanup EXIT
trap 'on_error $LINENO' ERR

# run CMD...  : executes, or only prints in dry-run mode (for every state-changing command)
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '    [dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed or not on PATH. $2"; }

# version_ge A B  -> true when A >= B (version sort)
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

csv_to_json() { printf '%s' "$1" | jq -R -c 'split(",") | map(gsub(" ";"")) | map(select(length>0))'; }

is_true() { [[ "$1" == "true" ]]; }


# installer_policy_json : least-privilege IAM policy for whoever RUNS this script
installer_policy_json() {
  local P="$PARTITION" R="$AWS_REGION" A="$AWS_ACCOUNT_ID" C="$CLUSTER_NAME"
  cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "CloudFormationKarpenterStack", "Effect": "Allow",
     "Action": ["cloudformation:CreateChangeSet","cloudformation:ExecuteChangeSet","cloudformation:DescribeChangeSet","cloudformation:DeleteChangeSet",
                "cloudformation:CreateStack","cloudformation:UpdateStack","cloudformation:DeleteStack","cloudformation:DescribeStacks",
                "cloudformation:DescribeStackEvents","cloudformation:DescribeStackResources","cloudformation:ListStackResources",
                "cloudformation:GetTemplate","cloudformation:GetTemplateSummary"],
     "Resource": "arn:${P}:cloudformation:${R}:${A}:stack/Karpenter-${C}/*"},
    {"Sid": "CloudFormationTemplateChecks", "Effect": "Allow",
     "Action": ["cloudformation:GetTemplateSummary","cloudformation:ValidateTemplate"], "Resource": "*"},
    {"Sid": "IamKarpenterRolesAndPolicies", "Effect": "Allow",
     "Action": ["iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:TagRole","iam:UntagRole","iam:UpdateAssumeRolePolicy",
                "iam:AttachRolePolicy","iam:DetachRolePolicy","iam:ListAttachedRolePolicies","iam:ListRolePolicies",
                "iam:CreatePolicy","iam:DeletePolicy","iam:GetPolicy","iam:GetPolicyVersion","iam:ListPolicyVersions",
                "iam:CreatePolicyVersion","iam:DeletePolicyVersion","iam:TagPolicy","iam:ListEntitiesForPolicy"],
     "Resource": ["arn:${P}:iam::${A}:role/KarpenterNodeRole-${C}","arn:${P}:iam::${A}:role/${C}-karpenter",
                  "arn:${P}:iam::${A}:policy/KarpenterController*-${C}"]},
    {"Sid": "IamPassControllerRoleToPodIdentity", "Effect": "Allow",
     "Action": "iam:PassRole", "Resource": "arn:${P}:iam::${A}:role/${C}-karpenter"},
    {"Sid": "IamOidcProviderForIrsa", "Effect": "Allow",
     "Action": ["iam:GetOpenIDConnectProvider","iam:CreateOpenIDConnectProvider","iam:TagOpenIDConnectProvider"],
     "Resource": "arn:${P}:iam::${A}:oidc-provider/oidc.eks.${R}.amazonaws.com/id/*"},
    {"Sid": "IamSpotServiceLinkedRole", "Effect": "Allow",
     "Action": "iam:CreateServiceLinkedRole",
     "Resource": "arn:${P}:iam::${A}:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot",
     "Condition": {"StringEquals": {"iam:AWSServiceName": "spot.amazonaws.com"}}},
    {"Sid": "IamSimulateForPreflight", "Effect": "Allow", "Action": "iam:SimulatePrincipalPolicy", "Resource": "*"},
    {"Sid": "SqsInterruptionQueue", "Effect": "Allow",
     "Action": ["sqs:CreateQueue","sqs:DeleteQueue","sqs:GetQueueUrl","sqs:GetQueueAttributes","sqs:SetQueueAttributes","sqs:TagQueue","sqs:ListQueueTags"],
     "Resource": "arn:${P}:sqs:${R}:${A}:${C}"},
    {"Sid": "EventBridgeRules", "Effect": "Allow",
     "Action": ["events:PutRule","events:DeleteRule","events:DescribeRule","events:PutTargets","events:RemoveTargets","events:ListTargetsByRule","events:TagResource"],
     "Resource": "arn:${P}:events:${R}:${A}:rule/Karpenter-${C}-*"},
    {"Sid": "EksClusterAccessAddonPodIdentity", "Effect": "Allow",
     "Action": ["eks:DescribeCluster","eks:UpdateClusterConfig","eks:DescribeUpdate",
                "eks:CreateAccessEntry","eks:DescribeAccessEntry","eks:UpdateAccessEntry",
                "eks:CreateAddon","eks:DescribeAddon","eks:UpdateAddon",
                "eks:CreatePodIdentityAssociation","eks:DescribePodIdentityAssociation","eks:UpdatePodIdentityAssociation","eks:ListPodIdentityAssociations",
                "eks:TagResource"],
     "Resource": ["arn:${P}:eks:${R}:${A}:cluster/${C}","arn:${P}:eks:${R}:${A}:access-entry/${C}/*",
                  "arn:${P}:eks:${R}:${A}:addon/${C}/*","arn:${P}:eks:${R}:${A}:podidentityassociation/${C}/*"]},
    {"Sid": "EksListCalls", "Effect": "Allow",
     "Action": ["eks:ListAccessEntries","eks:ListAddons","eks:DescribeAddonVersions","eks:ListPodIdentityAssociations"], "Resource": "*"},
    {"Sid": "Ec2ReadAndDiscoveryTags", "Effect": "Allow",
     "Action": ["ec2:DescribeSubnets","ec2:DescribeRouteTables","ec2:DescribeSecurityGroups","ec2:DescribeImages","ec2:DescribeVpcs"], "Resource": "*"},
    {"Sid": "Ec2CreateDiscoveryTags", "Effect": "Allow",
     "Action": "ec2:CreateTags",
     "Resource": ["arn:${P}:ec2:${R}:${A}:subnet/*","arn:${P}:ec2:${R}:${A}:security-group/*"]},
    {"Sid": "SsmEksAmiLookup", "Effect": "Allow",
     "Action": "ssm:GetParameter", "Resource": "arn:${P}:ssm:${R}::parameter/aws/service/eks/optimized-ami/*"}
  ]
}
JSON
}

###############################################################################
# 0. Input validation
###############################################################################
is_true "$PRINT_POLICY" || log "Step 0/8  Validating inputs"
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is required (export CLUSTER_NAME=... or use --cluster)."
[[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "Cluster name '$CLUSTER_NAME' has characters that are not valid in IAM/SQS names."
# IAM role name limit is 64: "KarpenterNodeRole-" (18) + cluster name  -> max 46
(( ${#CLUSTER_NAME} <= 46 )) || die "Cluster name is ${#CLUSTER_NAME} chars; the generated IAM role 'KarpenterNodeRole-<name>' would exceed IAM's 64-char limit (max 46)."
[[ "$AUTH_METHOD" == "pod-identity" || "$AUTH_METHOD" == "irsa" ]] || die "AUTH_METHOD must be 'pod-identity' or 'irsa'."
[[ "$KARPENTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "KARPENTER_VERSION must look like 1.15.1 (no leading 'v')."
[[ "$CPU_LIMIT" =~ ^[0-9]+$ ]] || die "CPU_LIMIT must be an integer."

if is_true "$PRINT_POLICY"; then
  command -v aws >/dev/null 2>&1 || [[ -n "$AWS_ACCOUNT_ID" ]] || die "aws CLI (or AWS_ACCOUNT_ID=<id>) is needed to print the policy."
  [[ -n "$AWS_REGION" ]] || AWS_REGION="$(aws configure get region 2>/dev/null || true)"
  [[ -n "$AWS_REGION" ]] || die "Set AWS_REGION to print the policy."
  [[ -n "$AWS_ACCOUNT_ID" ]] || AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  PARTITION="${PARTITION:-aws}"
  installer_policy_json
  exit 0
fi

need_cmd aws  "Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
need_cmd kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
need_cmd helm "Install Helm >= 3.8: https://helm.sh/docs/intro/install/"
need_cmd jq   "Install jq: https://jqlang.github.io/jq/download/"
need_cmd curl "Install curl."
need_cmd sort "coreutils is required."

AWS_CLI_VERSION="$(aws --version 2>&1 | sed -E 's#^aws-cli/([0-9.]+).*#\1#')"
[[ "${AWS_CLI_VERSION%%.*}" == "2" ]] || die "AWS CLI v2 is required (found $AWS_CLI_VERSION)."
version_ge "$AWS_CLI_VERSION" "2.36.21" || warn "AWS CLI $AWS_CLI_VERSION is older than 2.36.21 (the version the Karpenter docs recommend). Upgrading is advised."

HELM_VERSION="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')"
[[ -n "$HELM_VERSION" ]] || die "Could not determine the Helm version."
version_ge "$HELM_VERSION" "3.8.0" || die "Helm $HELM_VERSION is too old for OCI charts; need >= 3.8.0."

for cap in $(printf '%s' "$CAPACITY_TYPES" | tr ',' ' '); do
  [[ "$cap" == "on-demand" || "$cap" == "spot" ]] || die "CAPACITY_TYPES entries must be on-demand and/or spot (got '$cap')."
done
for arch in $(printf '%s' "$NODE_ARCH" | tr ',' ' '); do
  [[ "$arch" == "amd64" || "$arch" == "arm64" ]] || die "NODE_ARCH entries must be amd64 and/or arm64 (got '$arch')."
done
CAP_JSON="$(csv_to_json "$CAPACITY_TYPES")"
ARCH_JSON="$(csv_to_json "$NODE_ARCH")"
CAT_JSON="$(csv_to_json "$INSTANCE_CATEGORIES")"
ok "tools OK  (aws-cli $AWS_CLI_VERSION, helm $HELM_VERSION, kubectl, jq)"

export AWS_PAGER=""          # never let the AWS CLI open a pager inside a script
if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(aws configure get region 2>/dev/null || true)"
fi
[[ -n "$AWS_REGION" ]] || die "AWS region not set. Use AWS_REGION=<region> or --region."
export AWS_DEFAULT_REGION="$AWS_REGION"

###############################################################################
# 1. Pre-flight: AWS identity + cluster
###############################################################################
log "Step 1/8  Pre-flight checks (read-only)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>&1)" \
  || die "AWS credentials are not working: $CALLER_ARN"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PARTITION="$(cut -d: -f2 <<<"$CALLER_ARN")"
ok "AWS identity: $CALLER_ARN"
info "account=$AWS_ACCOUNT_ID  partition=$PARTITION  region=$AWS_REGION"


# --- permission probes: every call below is read-only, uses names that cannot exist, and
#     only distinguishes "AccessDenied" from "not found" / "validation error".
DENIED=()
probe() {
  local out
  out="$("$@" 2>&1)" && return 0
  if grep -Eqi 'AccessDenied|not authorized|UnauthorizedOperation|AuthorizationError' <<<"$out"; then
    local act
    act="$(sed -nE 's/.*perform: ([A-Za-z0-9:*]+).*/\1/p' <<<"$out" | head -n1)"
    DENIED+=("${act:-unknown-action ($1 $2 $3)}")
  fi
  return 0
}
POL_PREFIX="arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:policy"
probe aws cloudformation describe-stacks       --stack-name "Karpenter-${CLUSTER_NAME}"
probe aws cloudformation describe-stack-events --stack-name "Karpenter-${CLUSTER_NAME}"
probe aws cloudformation list-stack-resources  --stack-name "Karpenter-${CLUSTER_NAME}"
probe aws iam get-role   --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
probe aws iam get-policy --policy-arn "${POL_PREFIX}/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}"
probe aws iam list-entities-for-policy --policy-arn "${POL_PREFIX}/KarpenterControllerPolicy-${CLUSTER_NAME}"
probe aws sqs get-queue-url --queue-name "${CLUSTER_NAME}"
probe aws eks describe-cluster --name "${CLUSTER_NAME}"
probe aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" --principal-arn "arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
probe aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}"
probe aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent
probe aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}"
probe aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-00000000"
probe aws ec2 describe-images --image-ids ami-00000000000000000
probe aws ssm get-parameter --name /aws/service/eks/optimized-ami/1.31/amazon-linux-2023/x86_64/standard/recommended/image_id
probe aws events describe-rule --name "karpenter-permission-probe-does-not-exist"

# --- write permissions cannot be probed safely, so ask IAM to simulate them when allowed
SIM_ARN=""
case "$CALLER_ARN" in
  *:assumed-role/*) SIM_ARN="arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/$(cut -d/ -f2 <<<"$CALLER_ARN")" ;;
  *:user/*)         SIM_ARN="$CALLER_ARN" ;;
esac
SIM_NOTE=""
if [[ -n "$SIM_ARN" ]]; then
  sim() {   # sim <resource-arn> <action>...
    local res="$1" out; shift
    if ! out="$(aws iam simulate-principal-policy --policy-source-arn "$SIM_ARN" --action-names "$@" --resource-arns "$res" --output json 2>&1)"; then
      SIM_NOTE="$out"; return 1
    fi
    while IFS= read -r a; do [[ -n "$a" ]] && DENIED+=("$a"); done < <(jq -r '.EvaluationResults[] | select(.EvalDecision != "allowed") | .EvalActionName' <<<"$out")
    return 0
  }
  STACK_ARN="arn:${PARTITION}:cloudformation:${AWS_REGION}:${AWS_ACCOUNT_ID}:stack/Karpenter-${CLUSTER_NAME}/*"
  {
    sim "$STACK_ARN" cloudformation:CreateChangeSet cloudformation:ExecuteChangeSet cloudformation:DescribeChangeSet cloudformation:DescribeStackEvents &&
    sim "arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" iam:CreateRole iam:AttachRolePolicy iam:TagRole &&
    sim "${POL_PREFIX}/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}" iam:CreatePolicy iam:TagPolicy &&
    sim "arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter" iam:CreateRole iam:AttachRolePolicy iam:PassRole &&
    sim "arn:${PARTITION}:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:${CLUSTER_NAME}" sqs:CreateQueue sqs:SetQueueAttributes sqs:TagQueue &&
    sim "arn:${PARTITION}:events:${AWS_REGION}:${AWS_ACCOUNT_ID}:rule/Karpenter-${CLUSTER_NAME}-ScheduledChangeRule-X" events:PutRule events:PutTargets &&
    sim "arn:${PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" eks:CreateAccessEntry eks:CreateAddon eks:CreatePodIdentityAssociation &&
    sim "arn:${PARTITION}:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:subnet/subnet-x" ec2:CreateTags
  } || true
fi

if (( ${#DENIED[@]} > 0 )); then
  UNIQ="$(printf '%s\n' "${DENIED[@]}" | sort -u | sed 's/^/        - /')"
  die "The AWS identity running this script is missing permissions:
$UNIQ

  Identity: $CALLER_ARN
  Fix (an admin must do this once, e.g. in CloudShell or the console; then re-run this script):
    1. Generate the exact policy for this cluster:
         CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION ./karpenter-eks-setup.sh --print-policy > karpenter-installer-policy.json
    2. Attach it to the role/user above (role name = last part of the identity):
         aws iam put-role-policy --role-name <ROLE_NAME> --policy-name KarpenterInstaller --policy-document file://karpenter-installer-policy.json
  (For an IAM user use: aws iam put-user-policy --user-name <USER> ...)"
fi
if [[ -n "$SIM_NOTE" ]]; then
  warn "Could not pre-check write permissions (iam:SimulatePrincipalPolicy is not allowed for this identity). Read access is OK; write access will be confirmed when each step runs, and a denial will be reported with the exact missing action."
else
  ok "permission pre-check passed (read probes + IAM policy simulation)"
fi

CLUSTER_JSON="$(aws eks describe-cluster --name "$CLUSTER_NAME" --output json 2>&1)" \
  || die "Cannot describe EKS cluster '$CLUSTER_NAME' in $AWS_REGION. AWS said: $CLUSTER_JSON"
CLUSTER_STATUS="$(jq -r '.cluster.status' <<<"$CLUSTER_JSON")"
K8S_VERSION="$(jq -r '.cluster.version' <<<"$CLUSTER_JSON")"
AUTH_MODE="$(jq -r '.cluster.accessConfig.authenticationMode // "CONFIG_MAP"' <<<"$CLUSTER_JSON")"
OIDC_ISSUER="$(jq -r '.cluster.identity.oidc.issuer // ""' <<<"$CLUSTER_JSON")"
VPC_ID="$(jq -r '.cluster.resourcesVpcConfig.vpcId' <<<"$CLUSTER_JSON")"
CLUSTER_SG="$(jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId // ""' <<<"$CLUSTER_JSON")"
CLUSTER_SUBNETS="$(jq -r '.cluster.resourcesVpcConfig.subnetIds | join(" ")' <<<"$CLUSTER_JSON")"
ZONAL_SHIFT_ON="$(jq -r '.cluster.zonalShiftConfig.enabled // false' <<<"$CLUSTER_JSON")"
[[ "$CLUSTER_STATUS" == "ACTIVE" ]] || die "Cluster status is $CLUSTER_STATUS; it must be ACTIVE."
ok "cluster '$CLUSTER_NAME': Kubernetes $K8S_VERSION, auth mode $AUTH_MODE, vpc $VPC_ID"

if ! is_true "$SKIP_VERSION_CHECK"; then
  if [[ "$KARPENTER_VERSION" == 1.15.* ]]; then
    version_ge "$K8S_VERSION" "1.31" || die "Karpenter 1.15 supports Kubernetes 1.31-1.37; cluster is $K8S_VERSION. Upgrade the cluster or set KARPENTER_VERSION to a compatible release (SKIP_VERSION_CHECK=true to bypass)."
    version_ge "1.37" "$K8S_VERSION" || die "Karpenter 1.15 supports Kubernetes 1.31-1.37; cluster is $K8S_VERSION. Check https://karpenter.sh/docs/upgrading/compatibility/ (SKIP_VERSION_CHECK=true to bypass)."
  else
    warn "KARPENTER_VERSION=$KARPENTER_VERSION: verify Kubernetes $K8S_VERSION is supported at https://karpenter.sh/docs/upgrading/compatibility/"
  fi
fi

if is_true "$ENABLE_ZONAL_SHIFT" && [[ "$ZONAL_SHIFT_ON" != "true" ]]; then
  die "ENABLE_ZONAL_SHIFT=true but zonal shift is not enabled on the cluster. Run: aws eks update-cluster-config --name $CLUSTER_NAME --zonal-shift-config enabled=true   (or leave ENABLE_ZONAL_SHIFT=false)"
fi
if [[ "$AUTH_METHOD" == "irsa" && -z "$OIDC_ISSUER" ]]; then
  die "AUTH_METHOD=irsa needs an OIDC issuer, but this cluster has none."
fi

# --- kubectl access, using a private kubeconfig so your own ~/.kube/config is never touched
export KUBECONFIG="$WORKDIR/kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" >/dev/null
NODES_JSON="$(kubectl get nodes -o json --request-timeout=30s 2>&1)" \
  || die "kubectl cannot talk to the cluster. Typical causes: (a) your IAM identity ($CALLER_ARN) has no EKS access entry / aws-auth mapping, (b) the API endpoint is private-only and you are outside the VPC. kubectl said: $NODES_JSON"
ok "kubectl can reach the cluster"

READY_NODES="$(jq '[.items[]
    | select((.metadata.labels["karpenter.sh/nodepool"] // "") == "")
    | select((.metadata.labels["eks.amazonaws.com/compute-type"] // "") != "fargate")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ] | length' <<<"$NODES_JSON")"
(( READY_NODES >= 1 )) || die "Karpenter must run on a node it does not manage. Found 0 Ready non-Fargate, non-Karpenter nodes. Add a managed node group first."
if [[ -z "$REPLICAS" ]]; then
  if (( READY_NODES >= 2 )); then REPLICAS=2; else REPLICAS=1; fi
fi
ok "$READY_NODES regular Ready node(s) available  ->  Karpenter replicas = $REPLICAS"
if (( REPLICAS > READY_NODES )); then
  die "REPLICAS=$REPLICAS but only $READY_NODES eligible node(s): the controller uses hard anti-affinity, so extra replicas would stay Pending forever."
fi

# --- existing Karpenter install?
if HELM_JSON="$(helm list -A -o json 2>&1)"; then :; else warn "Could not list Helm releases ($HELM_JSON); skipping existing-install check."; HELM_JSON='[]'; fi
EXISTING_NS="$(jq -r '[.[] | select(.name=="karpenter")] | .[0].namespace // ""' <<<"$HELM_JSON")"
EXISTING_CHART="$(jq -r '[.[] | select(.name=="karpenter")] | .[0].chart // ""' <<<"$HELM_JSON")"
if [[ -n "$EXISTING_NS" ]]; then
  EXISTING_VER="${EXISTING_CHART#karpenter-}"
  info "found existing Helm release 'karpenter' in namespace '$EXISTING_NS' (chart $EXISTING_CHART)"
  [[ "$EXISTING_NS" == "$KARPENTER_NAMESPACE" ]] \
    || die "Karpenter is already installed in namespace '$EXISTING_NS' but this run targets '$KARPENTER_NAMESPACE'. A Pod Identity/IRSA binding is namespace-specific, so mixing them is the #1 cause of permission failures. Either set KARPENTER_NAMESPACE=$EXISTING_NS, or remove the old one: helm uninstall karpenter -n $EXISTING_NS"
  [[ "${EXISTING_VER%%.*}" -ge 1 ]] 2>/dev/null \
    || die "Existing Karpenter release is $EXISTING_VER (pre-1.0, v1beta1 API). Do NOT upgrade over it with this script; follow https://karpenter.sh/docs/upgrading/upgrade-guide/ or uninstall it first."
fi
if CRD_JSON="$(kubectl get crd nodepools.karpenter.sh -o json 2>/dev/null)"; then
  jq -e '[.spec.versions[].name] | index("v1")' <<<"$CRD_JSON" >/dev/null \
    || die "Found legacy Karpenter CRDs without the v1 API (old v1beta1 install). Follow the official upgrade guide or delete the old Karpenter completely before running this script."
  ok "existing Karpenter v1 CRDs found (they will be refreshed to match chart $KARPENTER_VERSION)"
fi

# --- the chart must be pullable from this machine
helm registry logout public.ecr.aws >/dev/null 2>&1 || true
helm show chart oci://public.ecr.aws/karpenter/karpenter --version "$KARPENTER_VERSION" >/dev/null 2>"$WORKDIR/helm.err" \
  || die "Cannot pull oci://public.ecr.aws/karpenter/karpenter:$KARPENTER_VERSION from this machine: $(cat "$WORKDIR/helm.err")"
ok "Helm chart karpenter $KARPENTER_VERSION is reachable"

# --- leftovers from earlier failed attempts (the usual cause of 'already exists' errors)
STACK_NAME="Karpenter-${CLUSTER_NAME}"
NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
NODE_ROLE_ARN="arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${NODE_ROLE_NAME}"
CONTROLLER_ROLE_NAME="${CLUSTER_NAME}-karpenter"
CONTROLLER_ROLE_ARN="arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CONTROLLER_ROLE_NAME}"
POLICY_NAMES=(
  "KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}"
  "KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}"
  "KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}"
  "KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}"
  "KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}"
  "KarpenterControllerZonalShiftPolicy-${CLUSTER_NAME}"
)
policy_arn() { printf 'arn:%s:iam::%s:policy/%s' "$PARTITION" "$AWS_ACCOUNT_ID" "$1"; }

if STACK_OUT="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>&1)"; then
  STACK_STATUS="$STACK_OUT"
elif grep -qi 'does not exist' <<<"$STACK_OUT"; then
  STACK_STATUS="NONE"
else
  die "Could not read CloudFormation stack $STACK_NAME: $STACK_OUT"
fi
info "CloudFormation stack $STACK_NAME: $STACK_STATUS"
case "$STACK_STATUS" in
  NONE)
    if aws iam get-role --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1; then
      die "IAM role $NODE_ROLE_NAME already exists but is NOT owned by the CloudFormation stack (leftover from an earlier attempt), so the stack would fail with 'already exists'. If nothing uses it, remove it: aws iam list-attached-role-policies --role-name $NODE_ROLE_NAME ; detach each policy ; aws iam delete-role --role-name $NODE_ROLE_NAME. If your nodes DO use it, use a different CLUSTER_NAME-based setup or import it manually."
    fi
    if aws sqs get-queue-url --queue-name "$CLUSTER_NAME" >/dev/null 2>&1; then
      die "An SQS queue named '$CLUSTER_NAME' already exists outside the stack (leftover). Delete it (aws sqs delete-queue --queue-url \$(aws sqs get-queue-url --queue-name $CLUSTER_NAME --query QueueUrl --output text)), wait 60s, and re-run."
    fi
    for p in "${POLICY_NAMES[@]}"; do
      if aws iam get-policy --policy-arn "$(policy_arn "$p")" >/dev/null 2>&1; then
        die "IAM policy $p already exists outside the stack (leftover). Detach it from all roles and delete it, then re-run: aws iam delete-policy --policy-arn $(policy_arn "$p")"
      fi
    done
    ok "no conflicting leftovers"
    ;;
  CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
    RES_IDS="$(aws cloudformation list-stack-resources --stack-name "$STACK_NAME" --query 'StackResourceSummaries[].LogicalResourceId' --output text)"
    if grep -qw 'KarpenterControllerPolicy' <<<"$RES_IDS" && ! grep -qw 'NodeLifecyclePolicy' <<<"$RES_IDS"; then
      LEGACY_ARN="$(policy_arn "KarpenterControllerPolicy-${CLUSTER_NAME}")"
      LEGACY_ROLES="$(aws iam list-entities-for-policy --policy-arn "$LEGACY_ARN" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || true)"
      warn "Stack was created by an OLD template (single KarpenterControllerPolicy). This is a prime cause of permission breakdowns with Karpenter 1.x."
      if [[ -n "$LEGACY_ROLES" && "$LEGACY_ROLES" != "None" ]]; then
        if is_true "$FORCE_CLEANUP"; then
          for r in $LEGACY_ROLES; do
            info "detaching legacy policy from role $r"
            run aws iam detach-role-policy --role-name "$r" --policy-arn "$LEGACY_ARN"
          done
        else
          die "The legacy policy $LEGACY_ARN is attached to role(s): $LEGACY_ROLES. CloudFormation cannot replace it while attached. Re-run with FORCE_CLEANUP=true to let this script detach it (the new 6 policies are attached to the controller role later in this script)."
        fi
      fi
    fi
    ok "existing stack is healthy and will be updated in place"
    ;;
  *_IN_PROGRESS)
    die "Stack $STACK_NAME is busy ($STACK_STATUS). Wait for it to finish and re-run." ;;
  *)
    if is_true "$FORCE_CLEANUP"; then
      warn "Stack is in state $STACK_STATUS; deleting it because FORCE_CLEANUP=true"
      run aws cloudformation delete-stack --stack-name "$STACK_NAME"
      run aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
    else
      die "Stack $STACK_NAME is in state $STACK_STATUS (a failed earlier attempt). It must be deleted before it can be re-created. Re-run with FORCE_CLEANUP=true, or run: aws cloudformation delete-stack --stack-name $STACK_NAME && aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME"
    fi
    ;;
esac

###############################################################################
# Plan + confirmation
###############################################################################
cat <<PLAN

  ┌─────────────────────────────────────────────────────────────
  │ Karpenter $KARPENTER_VERSION  ->  EKS cluster '$CLUSTER_NAME' ($AWS_REGION)
  │ Namespace ........ $KARPENTER_NAMESPACE      replicas: $REPLICAS
  │ Controller auth .. $AUTH_METHOD   role: $CONTROLLER_ROLE_NAME
  │ Node role ........ $NODE_ROLE_NAME
  │ NodePool ......... $NODEPOOL_NAME  (cap types: $CAPACITY_TYPES, arch: $NODE_ARCH, limit: $CPU_LIMIT vCPU)
  │ Smoke test ....... $SMOKE_TEST      Dry run: $DRY_RUN
  └─────────────────────────────────────────────────────────────
PLAN
if ! is_true "$DRY_RUN" && ! is_true "$ASSUME_YES" && [[ -t 0 ]]; then
  read -r -p "  Proceed and create/modify the resources above? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

###############################################################################
# 2. CloudFormation: node role, controller policies, SQS queue, EventBridge
###############################################################################
log "Step 2/8  CloudFormation stack $STACK_NAME"
TEMPLATE="$WORKDIR/cloudformation.yaml"
if [[ -n "$CFN_TEMPLATE_FILE" ]]; then
  cp "$CFN_TEMPLATE_FILE" "$TEMPLATE"
else
  TEMPLATE_URL="https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml"
  curl -fsSL --retry 3 --max-time 60 -o "$TEMPLATE" "$TEMPLATE_URL" \
    || die "Could not download $TEMPLATE_URL . If this machine blocks raw.githubusercontent.com, download the file elsewhere and re-run with CFN_TEMPLATE_FILE=/path/to/cloudformation.yaml"
fi
head -n1 "$TEMPLATE" | grep -q 'AWSTemplateFormatVersion' || die "Downloaded template does not look like a CloudFormation template."
grep -q 'KarpenterControllerNodeLifecyclePolicy' "$TEMPLATE" \
  || die "Template does not contain the 6-policy controller layout; KARPENTER_VERSION=$KARPENTER_VERSION may be too old for this script (needs >= 1.9)."
TEMPLATE_BYTES="$(wc -c <"$TEMPLATE" | tr -d ' ')"
(( TEMPLATE_BYTES < 51200 )) || die "Template is $TEMPLATE_BYTES bytes (>51,200); 'aws cloudformation deploy' would need an S3 bucket."

DEPLOY_LOG="$WORKDIR/deploy.log"
if ! run aws cloudformation deploy \
      --stack-name "$STACK_NAME" \
      --template-file "$TEMPLATE" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
      --no-fail-on-empty-changeset 2>&1 | tee "$DEPLOY_LOG"; then
  EVENTS="$(aws cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output text 2>&1 | head -n 20 || true)"
  if grep -qi 'AccessDenied' <<<"$EVENTS"; then EVENTS="(not readable: this identity may not call cloudformation:DescribeStackEvents)"; fi
  MISSING="$( { printf '%s\n' "$EVENTS"; cat "$DEPLOY_LOG"; } | grep -Eo 'perform: [A-Za-z0-9:*]+' | awk '{print $2}' | sort -u | tr '\n' ' ' || true)"
  [[ -z "$EVENTS" ]] || printf '    Stack failure reasons:\n%s\n' "$EVENTS" >&2
  if [[ -n "$MISSING" ]]; then
    die "CloudFormation failed because this identity ($CALLER_ARN) lacks: $MISSING
  Generate and attach the exact policy:  CLUSTER_NAME=$CLUSTER_NAME AWS_REGION=$AWS_REGION ./karpenter-eks-setup.sh --print-policy"
  fi
  die "CloudFormation deployment failed; the AWS error is printed above. If it says 'already exists', delete the leftover named in the message and re-run."
fi
if ! is_true "$DRY_RUN"; then
  for p in "${POLICY_NAMES[@]}"; do
    aws iam get-policy --policy-arn "$(policy_arn "$p")" >/dev/null 2>&1 || die "Expected IAM policy $p is missing after the stack deployed."
  done
  aws iam get-role --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1 || die "Node role $NODE_ROLE_NAME is missing after the stack deployed."
  aws sqs get-queue-url --queue-name "$CLUSTER_NAME" >/dev/null 2>&1 || die "Interruption queue '$CLUSTER_NAME' is missing after the stack deployed."
  ok "stack deployed: node role, 6 controller policies, interruption queue all present"
fi

###############################################################################
# 3. Discovery tags on subnets + security group
###############################################################################
log "Step 3/8  Discovery tags (karpenter.sh/discovery=$CLUSTER_NAME)"
is_private_subnet() {   # true when the subnet's route table has NO 0.0.0.0/0 -> igw route
  local sid="$1" rt_json igw_routes
  rt_json="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$sid" --output json)"
  if [[ "$(jq '.RouteTables | length' <<<"$rt_json")" == "0" ]]; then
    rt_json="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --output json)"
  fi
  igw_routes="$(jq '[.RouteTables[0].Routes[]? | select(.DestinationCidrBlock=="0.0.0.0/0" and ((.GatewayId // "") | startswith("igw-")))] | length' <<<"$rt_json")"
  [[ "$igw_routes" == "0" ]]
}

TAG_SUBNETS=()
if [[ -n "$SUBNET_IDS" ]]; then
  IFS=',' read -r -a TAG_SUBNETS <<<"${SUBNET_IDS// /}"
  info "using SUBNET_IDS from environment: ${TAG_SUBNETS[*]}"
else
  for s in $CLUSTER_SUBNETS; do
    if is_private_subnet "$s"; then TAG_SUBNETS+=("$s"); else info "skipping public subnet $s"; fi
  done
  (( ${#TAG_SUBNETS[@]} > 0 )) || die "None of the cluster's subnets are private. Set SUBNET_IDS=subnet-aaa,subnet-bbb to choose the subnets Karpenter may launch nodes in."
  info "private subnets selected: ${TAG_SUBNETS[*]}"
fi
TAG_RESOURCES=("${TAG_SUBNETS[@]}")
if [[ -n "$CLUSTER_SG" ]]; then TAG_RESOURCES+=("$CLUSTER_SG"); else warn "Cluster has no clusterSecurityGroupId; tag your node security group manually with karpenter.sh/discovery=$CLUSTER_NAME."; fi
run aws ec2 create-tags --resources "${TAG_RESOURCES[@]}" --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
changed "tagged ${TAG_RESOURCES[*]}" "tag ${TAG_RESOURCES[*]}"

TAGGED_NOW="$(aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)"
for s in $TAGGED_NOW; do
  if [[ ! " ${TAG_SUBNETS[*]} " =~ \ ${s}\  ]]; then
    warn "Subnet $s ALSO carries the discovery tag (older attempt?) so Karpenter will use it. Remove with: aws ec2 delete-tags --resources $s --tags Key=karpenter.sh/discovery"
  fi
done

if [[ " $CAPACITY_TYPES " == *spot* || "$CAPACITY_TYPES" == *spot* ]]; then
  info "spot enabled: making sure the EC2 Spot service-linked role exists"
  if is_true "$DRY_RUN"; then
    run aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
  else
    aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >/dev/null 2>&1 || true
  fi
fi

###############################################################################
# 4. Let Karpenter-launched nodes join the cluster
###############################################################################
log "Step 4/8  Node role -> cluster access ($AUTH_MODE)"
case "$AUTH_MODE" in
  API|API_AND_CONFIG_MAP)
    if aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$NODE_ROLE_ARN" >/dev/null 2>&1; then
      ok "access entry for $NODE_ROLE_NAME already exists"
    else
      run aws eks create-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$NODE_ROLE_ARN" --type EC2_LINUX >/dev/null
      changed "created EC2_LINUX access entry for $NODE_ROLE_NAME" "create EC2_LINUX access entry for $NODE_ROLE_NAME"
    fi
    ;;
  CONFIG_MAP)
    if is_true "$AUTH_MODE_UPGRADE"; then
      warn "Upgrading cluster authentication mode CONFIG_MAP -> API_AND_CONFIG_MAP (one-way, existing aws-auth entries keep working)"
      run aws eks update-cluster-config --name "$CLUSTER_NAME" --access-config authenticationMode=API_AND_CONFIG_MAP >/dev/null
      if ! is_true "$DRY_RUN"; then sleep 20; aws eks wait cluster-active --name "$CLUSTER_NAME"; fi
      run aws eks create-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$NODE_ROLE_ARN" --type EC2_LINUX >/dev/null
    elif command -v eksctl >/dev/null 2>&1; then
      info "cluster uses aws-auth only; adding the mapping with eksctl"
      if eksctl get iamidentitymapping --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --arn "$NODE_ROLE_ARN" >/dev/null 2>&1; then
        ok "aws-auth mapping already present"
      else
        run eksctl create iamidentitymapping --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --arn "$NODE_ROLE_ARN" \
          --username 'system:node:{{EC2PrivateDNSName}}' --group system:bootstrappers --group system:nodes
      fi
    else
      die "Cluster authentication mode is CONFIG_MAP (aws-auth only). Either install eksctl (used to edit aws-auth safely), or re-run with AUTH_MODE_UPGRADE=true to switch the cluster to API_AND_CONFIG_MAP."
    fi
    ;;
  *) die "Unknown authentication mode '$AUTH_MODE'." ;;
esac

###############################################################################
# 5. Controller IAM role + binding to the 'karpenter' service account
###############################################################################
log "Step 5/8  Controller IAM role '$CONTROLLER_ROLE_NAME' ($AUTH_METHOD)"
if [[ "$AUTH_METHOD" == "pod-identity" ]]; then
  TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
else
  OIDC_HOST="${OIDC_ISSUER#https://}"
  OIDC_PROVIDER_ARN="arn:${PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
    ok "IAM OIDC provider already registered"
  else
    run aws iam create-open-id-connect-provider --url "$OIDC_ISSUER" --client-id-list sts.amazonaws.com >/dev/null
    changed "registered IAM OIDC provider for the cluster" "register IAM OIDC provider for the cluster"
  fi
  TRUST_POLICY="$(jq -n -c --arg p "$OIDC_PROVIDER_ARN" --arg h "$OIDC_HOST" --arg ns "$KARPENTER_NAMESPACE" \
    '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:$p},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{($h+":aud"):"sts.amazonaws.com",($h+":sub"):("system:serviceaccount:"+$ns+":karpenter")}}}]}')"
fi

if aws iam get-role --role-name "$CONTROLLER_ROLE_NAME" >/dev/null 2>&1; then
  run aws iam update-assume-role-policy --role-name "$CONTROLLER_ROLE_NAME" --policy-document "$TRUST_POLICY"
  ok "role exists; trust policy refreshed"
else
  run aws iam create-role --role-name "$CONTROLLER_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" \
    --description "Karpenter controller for EKS cluster ${CLUSTER_NAME}" >/dev/null
  if ! is_true "$DRY_RUN"; then aws iam wait role-exists --role-name "$CONTROLLER_ROLE_NAME"; sleep "$IAM_SETTLE_SECONDS"; fi
  changed "created role $CONTROLLER_ROLE_NAME" "create role $CONTROLLER_ROLE_NAME"
fi
for p in "${POLICY_NAMES[@]}"; do
  run aws iam attach-role-policy --role-name "$CONTROLLER_ROLE_NAME" --policy-arn "$(policy_arn "$p")"
done
changed "attached the 6 Karpenter controller policies" "attach the 6 Karpenter controller policies"

if [[ "$AUTH_METHOD" == "pod-identity" ]]; then
  if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent >/dev/null 2>&1; then
    ok "eks-pod-identity-agent add-on already installed"
  else
    info "installing the eks-pod-identity-agent add-on"
    run aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent --resolve-conflicts OVERWRITE >/dev/null
    if ! is_true "$DRY_RUN"; then aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name eks-pod-identity-agent; fi
  fi
  if ! is_true "$DRY_RUN"; then
    kubectl -n kube-system rollout status ds/eks-pod-identity-agent --timeout=300s >/dev/null \
      || die "eks-pod-identity-agent DaemonSet is not ready. Pod Identity cannot work without it (it also needs the node role to allow eks-auth:AssumeRoleForPodIdentity, which AmazonEKSWorkerNodePolicy includes). Or re-run with AUTH_METHOD=irsa."
  fi
  ASSOC_ID="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$KARPENTER_NAMESPACE" --service-account karpenter --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"
  if [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]]; then
    CUR_ROLE="$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --query 'association.roleArn' --output text)"
    if [[ "$CUR_ROLE" == "$CONTROLLER_ROLE_ARN" ]]; then
      ok "Pod Identity association already points at $CONTROLLER_ROLE_NAME"
    else
      run aws eks update-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --role-arn "$CONTROLLER_ROLE_ARN" >/dev/null
      changed "re-pointed Pod Identity association from $CUR_ROLE" "re-point Pod Identity association from $CUR_ROLE"
    fi
  else
    run aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --namespace "$KARPENTER_NAMESPACE" \
      --service-account karpenter --role-arn "$CONTROLLER_ROLE_ARN" >/dev/null
    changed "created Pod Identity association ${KARPENTER_NAMESPACE}/karpenter -> $CONTROLLER_ROLE_NAME" "create Pod Identity association ${KARPENTER_NAMESPACE}/karpenter -> $CONTROLLER_ROLE_NAME"
  fi
fi

###############################################################################
# 6. Helm install
###############################################################################
log "Step 6/8  Installing Karpenter $KARPENTER_VERSION with Helm"
CRDS_YAML="$(helm show crds oci://public.ecr.aws/karpenter/karpenter --version "$KARPENTER_VERSION" 2>/dev/null || true)"
if [[ -n "$CRDS_YAML" ]]; then
  if is_true "$DRY_RUN"; then
    printf '    [dry-run] kubectl apply --server-side --force-conflicts -f <CRDs of chart %s>\n' "$KARPENTER_VERSION"
  else
    kubectl apply --server-side --force-conflicts -f - <<<"$CRDS_YAML" >/dev/null
    ok "CRDs match chart $KARPENTER_VERSION"
  fi
fi

HELM_ARGS=(
  upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter
  --version "$KARPENTER_VERSION"
  --namespace "$KARPENTER_NAMESPACE" --create-namespace
  --set "settings.clusterName=${CLUSTER_NAME}"
  --set "settings.interruptionQueue=${CLUSTER_NAME}"
  --set "settings.enableZonalShift=${ENABLE_ZONAL_SHIFT}"
  --set "replicas=${REPLICAS}"
  --set "controller.resources.requests.cpu=${CONTROLLER_CPU}"
  --set "controller.resources.requests.memory=${CONTROLLER_MEMORY}"
  --set "controller.resources.limits.cpu=${CONTROLLER_CPU}"
  --set "controller.resources.limits.memory=${CONTROLLER_MEMORY}"
  --wait --timeout 10m
)
if [[ "$AUTH_METHOD" == "irsa" ]]; then
  HELM_ARGS+=(--set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${CONTROLLER_ROLE_ARN}")
fi
if ! run helm "${HELM_ARGS[@]}"; then
  warn "Helm install did not become ready. Pod status:"
  kubectl -n "$KARPENTER_NAMESPACE" get pods -l app.kubernetes.io/name=karpenter -o wide >&2 || true
  kubectl -n "$KARPENTER_NAMESPACE" describe pods -l app.kubernetes.io/name=karpenter 2>/dev/null | grep -A12 '^Events:' >&2 || true
  die "Karpenter pods are not Ready (see above). 'Insufficient cpu/memory' => lower CONTROLLER_CPU/CONTROLLER_MEMORY or add node capacity; 'didn't match pod anti-affinity' => REPLICAS is higher than your node count."
fi

if ! is_true "$DRY_RUN"; then
  kubectl -n "$KARPENTER_NAMESPACE" rollout status deployment/karpenter --timeout=300s >/dev/null
  pod_has_creds() {
    kubectl -n "$KARPENTER_NAMESPACE" get pods -l app.kubernetes.io/name=karpenter -o json |
      jq -e --arg v "$([[ "$AUTH_METHOD" == "pod-identity" ]] && echo AWS_CONTAINER_CREDENTIALS_FULL_URI || echo AWS_WEB_IDENTITY_TOKEN_FILE)" \
        '([.items[].spec.containers[] | select(.name=="controller") | [(.env // [])[].name] | index($v)]) | (length > 0 and all(. != null))' >/dev/null
  }
  if ! pod_has_creds; then
    warn "Controller pods have no AWS credentials injected yet; restarting them once so the $AUTH_METHOD binding is picked up"
    kubectl -n "$KARPENTER_NAMESPACE" rollout restart deployment/karpenter >/dev/null
    kubectl -n "$KARPENTER_NAMESPACE" rollout status deployment/karpenter --timeout=300s >/dev/null
    pod_has_creds || die "Controller pods still have no $AUTH_METHOD credentials. Check that the Pod Identity association / IRSA annotation uses namespace '$KARPENTER_NAMESPACE' and service account 'karpenter'."
  fi
  ok "Karpenter controller is running with AWS credentials ($AUTH_METHOD)"
  sleep "$LOG_SETTLE_SECONDS"
  BAD_LOGS="$(kubectl -n "$KARPENTER_NAMESPACE" logs deploy/karpenter -c controller --since=3m 2>&1 | grep -Ei 'accessdenied|unauthorizedoperation|not authorized|webidentityerr|nocredentialproviders|failed to refresh cached credentials' | head -n 8 || true)"
  if [[ -n "$BAD_LOGS" ]]; then
    warn "Controller logged permission-looking errors (may be transient, the next step is the real test):"
    printf '%s\n' "$BAD_LOGS" >&2
  fi
fi

###############################################################################
# 7. NodePool + EC2NodeClass
###############################################################################
log "Step 7/8  NodePool '$NODEPOOL_NAME' + EC2NodeClass '$NODECLASS_NAME'"
ALIAS_VERSION="latest"
if AMI_ID="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value --output text 2>/dev/null)" \
   && AMI_NAME="$(aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].Name' --output text 2>/dev/null)" \
   && [[ "$AMI_NAME" =~ (v[0-9]+)$ ]]; then
  ALIAS_VERSION="${BASH_REMATCH[1]}"
  ok "pinning AL2023 AMI release $ALIAS_VERSION (from $AMI_NAME)"
else
  warn "Could not resolve a pinned AL2023 AMI release; falling back to al2023@latest (every new AMI will roll nodes). Pin it later in the EC2NodeClass."
fi

if kubectl get nodepool "$NODEPOOL_NAME" >/dev/null 2>&1; then warn "NodePool '$NODEPOOL_NAME' already exists and will be overwritten."; fi
MANIFEST="$(cat <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${NODEPOOL_NAME}
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ${ARCH_JSON}
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ${CAP_JSON}
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ${CAT_JSON}
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ${NODECLASS_NAME}
      expireAfter: 720h
  limits:
    cpu: ${CPU_LIMIT}
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ${NODECLASS_NAME}
spec:
  role: "${NODE_ROLE_NAME}"
  amiSelectorTerms:
    - alias: "al2023@${ALIAS_VERSION}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF
)"
if is_true "$DRY_RUN"; then
  printf '    [dry-run] kubectl apply -f - <<EOF\n'; sed 's/^/        | /' <<<"$MANIFEST"; printf '    EOF\n'
else
  kubectl apply -f - <<<"$MANIFEST" >/dev/null
  ok "applied NodePool and EC2NodeClass"
fi

###############################################################################
# 8. Verification
###############################################################################
log "Step 8/8  Verification"
diagnose() {
  printf '\n  Recent controller errors:\n' >&2
  kubectl -n "$KARPENTER_NAMESPACE" logs deploy/karpenter -c controller --tail=200 2>&1 | grep -Ei 'error|denied|unauthorized|failed' | tail -n 12 >&2 || true
  printf '\n  Hints:\n  - AccessDenied / UnauthorizedOperation  => controller role is missing one of the 6 policies, or the Pod Identity/IRSA binding is for another namespace/service account.\n  - "no subnets/security groups found"      => discovery tags missing (Step 3).\n  - InstanceProfile errors                  => iam:*InstanceProfile / iam:PassRole on %s missing from the controller role.\n' "$NODE_ROLE_NAME" >&2
}
if is_true "$DRY_RUN"; then
  info "dry-run: skipping live verification and smoke test"
else
  if ! kubectl wait --for=condition=Ready "ec2nodeclass/${NODECLASS_NAME}" --timeout=240s >/dev/null 2>&1; then
    warn "EC2NodeClass '$NODECLASS_NAME' is not Ready. Unmet conditions:"
    kubectl get ec2nodeclass "$NODECLASS_NAME" -o json | jq -r '.status.conditions[]? | select(.status != "True") | "    - \(.type): \(.reason) - \(.message)"' >&2 || true
    diagnose
    die "EC2NodeClass is not Ready, so Karpenter cannot launch nodes yet (details above)."
  fi
  ok "EC2NodeClass is Ready (subnets, security groups, AMI and instance-profile permissions all validated by Karpenter)"

  if is_true "$SMOKE_TEST"; then
    info "launching a real test node (one pause pod pinned to NodePool '$NODEPOOL_NAME'); this takes 1-3 minutes"
    SMOKE_DEPLOYED=true
    kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-smoke-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: karpenter-smoke-test
  template:
    metadata:
      labels:
        app: karpenter-smoke-test
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        karpenter.sh/nodepool: ${NODEPOOL_NAME}
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
      containers:
        - name: pause
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: 500m
          securityContext:
            allowPrivilegeEscalation: false
EOF
    if ! kubectl wait --for=condition=Available deployment/karpenter-smoke-test -n default --timeout=600s >/dev/null 2>&1; then
      warn "Test pod did not start within 10 minutes."
      kubectl get nodeclaims -o wide >&2 || true
      kubectl describe nodeclaims -l "karpenter.sh/nodepool=${NODEPOOL_NAME}" 2>/dev/null | grep -A15 -i 'conditions\|events' | head -n 40 >&2 || true
      kubectl get events -n default --sort-by=.lastTimestamp 2>/dev/null | tail -n 8 >&2 || true
      diagnose
      die "Karpenter could not bring up a working node. Common causes: node role not mapped (Step 4), no NAT/endpoints for the subnet, vCPU quota exhausted, or the controller IAM binding (see hints)."
    fi
    NEW_NODE="$(kubectl get pods -n default -l app=karpenter-smoke-test -o jsonpath='{.items[0].spec.nodeName}')"
    ok "Karpenter launched and joined node $NEW_NODE; the test pod is Running"
    info "cleaning up the test workload; Karpenter will remove the empty node after ~1 minute"
    kubectl delete deployment karpenter-smoke-test -n default --wait=true >/dev/null
    SMOKE_DEPLOYED=false
    if kubectl wait --for=delete nodeclaim -l "karpenter.sh/nodepool=${NODEPOOL_NAME}" --timeout=480s >/dev/null 2>&1; then
      ok "test node was consolidated away"
    else
      warn "Test node is still shutting down; Karpenter will remove it shortly (kubectl get nodeclaims)."
    fi
  fi
fi

if is_true "$DRY_RUN"; then
  log "Dry run finished - NOTHING was changed"
  cat <<DONE

  All read-only checks passed. Review the [dry-run] lines above, then run the
  same command again without DRY_RUN=true (or --dry-run) to apply them.
DONE
  exit 0
fi

log "Done"
cat <<DONE

  Karpenter $KARPENTER_VERSION is installed on '$CLUSTER_NAME'.

  Watch it:      kubectl logs -f -n $KARPENTER_NAMESPACE -l app.kubernetes.io/name=karpenter -c controller
  Inspect:       kubectl get nodepools,ec2nodeclasses,nodeclaims
  Your kubectl:  aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
                 (this script used a throw-away kubeconfig and did not touch ~/.kube/config)
  Tip:           workloads that must land on Karpenter nodes just need resource requests;
                 Karpenter creates capacity for any Pending pod that fits the NodePool.
DONE
