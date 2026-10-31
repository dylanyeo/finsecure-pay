# shellcheck shell=bash
# shellcheck disable=SC2034  # constants and paths are used by the task files
# =============================================================================
# FinSecure Pay - shared helpers for finsecure.sh
# =============================================================================

# ----------------------------------------------------------------- constants
FS_NS="finsecure"
FS_DEPLOY="finsecure-pay"
FS_SVC="finsecure-pay"
FS_MON_NS="monitoring"
FS_MON_RELEASE="monitoring"
KPS_CHART_VERSION="92.13.1"
TRIVY_IMAGE="aquasec/trivy:0.76.1"
GITLEAKS_IMAGE="zricethezav/gitleaks:v8.30.1"
JENKINS_JOB="finsecure-pay"
VULN_LIB="commons-text"
VULN_LIB_BAD="1.9"        # CVE-2022-42889 "Text4Shell", CVSS 9.8
VULN_LIB_FIXED="1.15.0"

CONFIG_FILE="$ROOT/automation/config.env"
SECRETS_FILE="$ROOT/automation/secrets.env"
SECRETS_DIR="$ROOT/secrets"
EVIDENCE_DIR="$ROOT/evidence"
ANSIBLE_DIR="$ROOT/automation/ansible"
CURRENT_TASK="general"

# ----------------------------------------------------------------- output
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

info()   { printf '%s\n' "${C_BLUE}[i]${C_RESET} $*"; }
ok()     { printf '%s\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warn()   { printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()    { printf '%s\n' "${C_RED}[X]${C_RESET} $*" >&2; }
die()    { err "$*"; exit 1; }
header() { printf '\n%s\n' "${C_BOLD}${C_CYAN}=== $* ===${C_RESET}"; }
sub()    { printf '\n%s\n' "${C_BOLD}--- $* ---${C_RESET}"; }
hint()   { printf '%s\n' "${C_DIM}    $*${C_RESET}"; }

# Print a command, then run it (shows exactly what is executed - useful for screenshots)
run() {
  printf '%s\n' "${C_DIM}\$ $*${C_RESET}"
  "$@"
}

pause() {
  [[ "${FS_NONINTERACTIVE:-0}" == "1" ]] && return 0
  read -rp "Press Enter to continue... " _ || true
}

confirm() {
  [[ "${FS_YES:-0}" == "1" ]] && return 0
  local answer
  read -rp "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^[Yy] ]]
}

# ----------------------------------------------------------------- configuration
load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE - run: ./finsecure.sh 0 (Setup, step 1)"
  [[ -f "$SECRETS_FILE" ]] || die "Missing $SECRETS_FILE - run: ./finsecure.sh 0 (Setup, step 1)"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$SECRETS_FILE"

  GITHUB_REPO_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
  AWS_PROFILE="${AWS_PROFILE:-default}"
  EKS_SPOT="${EKS_SPOT:-false}"
  GITHUB_WEB_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
  DOCKERHUB_WEB_URL="https://hub.docker.com/r/${DOCKERHUB_REPO}/tags"
  if [[ -z "${JENKINS_HOST:-}" ]]; then
    JENKINS_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    JENKINS_HOST="${JENKINS_HOST:-127.0.0.1}"
  fi
  JENKINS_PORT="${JENKINS_PORT:-8080}"
  JENKINS_URL="http://${JENKINS_HOST}:${JENKINS_PORT}/"
  JENKINS_LOCAL="http://127.0.0.1:${JENKINS_PORT}"
  JENKINS_KUBECONFIG_FILE="$SECRETS_DIR/jenkins-kubeconfig.yaml"
  FINSECURE_USER="$(id -un)"

  export GITHUB_USER GITHUB_REPO GITHUB_REPO_URL DOCKERHUB_USER DOCKERHUB_REPO \
         AWS_REGION AWS_PROFILE EKS_CLUSTER EKS_VERSION EKS_NODE_COUNT EKS_INSTANCE_TYPE EKS_SPOT \
         SONAR_ENABLED SONAR_ORG SONAR_PROJECT_KEY SMTP_USER NOTIFY_EMAIL \
         JENKINS_ADMIN_USER JENKINS_PORT JENKINS_BIND_ADDRESS JENKINS_HOST JENKINS_URL \
         JENKINS_KUBECONFIG_FILE FINSECURE_USER \
         DOCKERHUB_TOKEN SONAR_TOKEN NVD_API_KEY SMTP_PASSWORD \
         JENKINS_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD FINSECURE_API_KEY
}

# Fail early if required settings are empty or still contain the example placeholders
require_vars() {
  local missing=() v
  for v in "$@"; do
    if [[ -z "${!v:-}" || "${!v}" == your-* || "${!v}" == *"your-"* || "${!v}" == "you@gmail.com" ]]; then
      missing+=("$v")
    fi
  done
  if ((${#missing[@]})); then
    die "Please set: ${missing[*]}  (edit automation/config.env / secrets.env or run ./finsecure.sh 0 -> 1)"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed - run ./finsecure.sh 0 -> step 2 (install tools)"
  done
}

# ----------------------------------------------------------------- docker
DOCKER=(docker)
detect_docker() {
  require_cmd docker
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
    warn "Using 'sudo docker'. Log out and back in (or run 'newgrp docker') to use docker without sudo."
  else
    die "Docker is not running or not accessible."
  fi
}
dk() { run "${DOCKER[@]}" "$@"; }

# ----------------------------------------------------------------- versions / git
app_version() {
  (cd "$ROOT" && ./mvnw -q -B -ntp help:evaluate -Dexpression=project.version -DforceStdout 2>/dev/null | tail -n 1)
}

set_app_version() {
  (cd "$ROOT" && run ./mvnw -q -B -ntp versions:set -DnewVersion="$1" -DgenerateBackupPoms=false)
}

# next_version 1.2.3 minor -> 1.3.0
next_version() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  case "$2" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    *)     echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

ensure_git_repo() {
  [[ -d "$ROOT/.git" ]] || die "This folder is not a git repository yet - run Task 1, step 3 first."
}

# git_commit_push "message" path...
git_commit_push() {
  local msg="$1"; shift
  ensure_git_repo
  (
    cd "$ROOT" || return 1
    run git add -- "$@"
    if git diff --cached --quiet; then
      warn "Nothing to commit for: $*"
      exit 0
    fi
    run git commit -m "$msg"
    run git push origin HEAD:main
  )
}

# ----------------------------------------------------------------- kubernetes
cluster_exists() {
  aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1
}

ensure_cluster_creds() {
  require_cmd aws kubectl
  aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --alias "$EKS_CLUSTER" >/dev/null 2>&1 \
    || die "Cannot reach EKS cluster '$EKS_CLUSTER'. Create it with ./finsecure.sh 3 -> step 1."
}

kc() { run kubectl -n "$FS_NS" "$@"; }

# render_deployment IMAGE BUILD_ID CHANGE_CAUSE  -> prints the rendered Deployment
render_deployment() {
  local cfg_sum
  cfg_sum="$(sha256sum "$ROOT/k8s/app/configmap.yaml" | cut -c1-16)"
  IMAGE="$1" BUILD_ID="$2" CHANGE_CAUSE="$3" CONFIG_CHECKSUM="$cfg_sum" \
    envsubst "\${IMAGE} \${BUILD_ID} \${CHANGE_CAUSE} \${CONFIG_CHECKSUM}" < "$ROOT/k8s/app/deployment.yaml"
}

# Prints the public address of the load balancer (AWS gives a DNS hostname). Waits up to ~5 minutes.
lb_address() {
  kubectl -n "$FS_NS" get svc "$FS_SVC" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

app_host() {
  local host="" i
  for i in $(seq 1 60); do
    host="$(lb_address)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
    [[ "$i" == 1 ]] && info "Waiting for AWS to create the Network Load Balancer (2-3 minutes)..." >&2
    sleep 5
  done
  return 1
}

# Sample requests
TX_APPROVED='{"transactionId":"TXN-DEMO-001","sourceAccount":"1234567890","destinationAccount":"9876543210","amount":250.50,"currency":"SGD"}'
TX_REJECTED='{"transactionId":"TXN-DEMO-002","sourceAccount":"1234567890","destinationAccount":"999999999999","amount":25000.999,"currency":"JPY"}'

# call_validate BASE_URL JSON [API_KEY]
call_validate() {
  local base="$1" body="$2" key="${3:-}"
  local -a hdr=(-H "Content-Type: application/json")
  [[ -n "$key" ]] && hdr+=(-H "X-API-Key: $key")
  printf '%s\n' "${C_DIM}\$ curl -s -X POST $base/validate -H 'Content-Type: application/json'${key:+ -H 'X-API-Key: ****'} -d '$body'${C_RESET}"
  curl -s -w '\nHTTP %{http_code}\n' -X POST "$base/validate" "${hdr[@]}" -d "$body"
}

# wait_for_health URL [expected-build-substring]
wait_for_health() {
  local url="$1" expect="${2:-}" i body
  for i in $(seq 1 90); do
    [[ "$i" == 2 ]] && info "Waiting for $url (new AWS load balancer DNS names take 2-4 minutes to resolve)..." >&2
    body="$(curl -fsS --max-time 5 "$url/health" 2>/dev/null || true)"
    if [[ -n "$body" && ( -z "$expect" || "$body" == *"$expect"* ) ]]; then
      run curl -s "$url/health"; echo
      return 0
    fi
    sleep 5
  done
  err "Timed out waiting for $url/health${expect:+ to report $expect}"
  return 1
}

# ----------------------------------------------------------------- jenkins REST API
# Credentials are passed to curl on stdin (-K -) so the password never appears in 'ps'
_jenkins_auth() { printf 'user = "%s:%s"\n' "$JENKINS_ADMIN_USER" "$JENKINS_ADMIN_PASSWORD"; }

jenkins_get() {
  _jenkins_auth | curl -fsS -K - "${JENKINS_LOCAL}$1"
}

jenkins_post() {
  local jar crumb
  mkdir -p "$SECRETS_DIR"
  jar="$SECRETS_DIR/.jenkins-cookies"
  crumb="$(_jenkins_auth | curl -fsS -K - -c "$jar" "${JENKINS_LOCAL}/crumbIssuer/api/json" \
           | jq -r '.crumbRequestField + ":" + .crumb')"
  _jenkins_auth | curl -fsS -K - -b "$jar" -H "$crumb" -X POST "${JENKINS_LOCAL}$1"
  rm -f "$jar"
}

jenkins_up() { curl -fsS -o /dev/null "${JENKINS_LOCAL}/login" 2>/dev/null; }

jenkins_last_build() {
  jenkins_get "/job/${JENKINS_JOB}/lastBuild/api/json?tree=number" 2>/dev/null | jq -r '.number // 0' 2>/dev/null || echo 0
}

jenkins_print_stages() {
  jenkins_get "/job/${JENKINS_JOB}/$1/wfapi/describe" 2>/dev/null \
    | jq -r '.stages[] | "  \(.status | .[0:11] | . + (" " * (11 - length)))  \(.name)  (\((.durationMillis/1000)|floor)s)"' 2>/dev/null || true
}

# Wait until a build newer than $1 starts (pipeline triggered by polling); prints its number
jenkins_wait_new_build() {
  local prev="$1" timeout="${2:-420}" waited=0 n
  info "Waiting for Jenkins to detect the commit and start build #$((prev + 1)) (polls every ~2 min)..." >&2
  while ((waited < timeout)); do
    n="$(jenkins_last_build)"
    if [[ "$n" =~ ^[0-9]+$ ]] && ((n > prev)); then
      ok "Jenkins started build #$n automatically" >&2
      echo "$n"
      return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  err "No new build after ${timeout}s. Check Jenkins: ${JENKINS_URL}job/${JENKINS_JOB}/"
  return 1
}

# Follow a build until it finishes; returns 0 for SUCCESS, 1 otherwise
jenkins_follow_build() {
  local n="$1" json building result last="" now
  info "Following build #$n: ${JENKINS_URL}job/${JENKINS_JOB}/$n/"
  while true; do
    json="$(jenkins_get "/job/${JENKINS_JOB}/$n/api/json?tree=building,result,description" 2>/dev/null || echo '{}')"
    building="$(jq -r '.building // true' <<<"$json")"
    result="$(jq -r '.result // "RUNNING"' <<<"$json")"
    now="$(jenkins_print_stages "$n")"
    if [[ "$now" != "$last" ]]; then
      printf '%s\n' "${C_DIM}[$(date +%H:%M:%S)] build #$n${C_RESET}"
      printf '%s\n' "$now"
      last="$now"
    fi
    [[ "$building" == "false" ]] && break
    sleep 15
  done
  printf '%s\n' "$(jq -r '"  description: " + (.description // "-")' <<<"$json")"
  if [[ "$result" == "SUCCESS" ]]; then
    ok "Build #$n finished: SUCCESS"
    return 0
  fi
  err "Build #$n finished: $result"
  return 1
}

jenkins_failed_stage() {
  jenkins_get "/job/${JENKINS_JOB}/$1/wfapi/describe" 2>/dev/null \
    | jq -r '[.stages[] | select(.status == "FAILED")][0].name // "none"' 2>/dev/null
}
