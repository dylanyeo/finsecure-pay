# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 0 - Setup: configuration, tools, cloud and GitHub login, pre-flight checks
# =============================================================================

task0_title="Setup (config, tools, logins, checks)"
task0_steps() {
  cat <<'EOF'
1|Create / update configuration (config.env + secrets.env)|t0_configure|no
2|Install tools with Ansible (Docker, Java 21, AWS CLI, eksctl, kubectl, Helm, gh)|t0_install_tools|yes
3|Configure AWS credentials and check access|t0_aws_login|no
4|Log in to GitHub CLI and set your git identity|t0_github_login|no
5|Pre-flight check (tools, config, logins)|t0_preflight|yes
EOF
}

# Value between the first pair of quotes (ignores trailing comments)
_get_var() {
  grep -E "^${2}=" "$1" | head -n 1 | sed -E 's/^[^=]+="([^"]*)".*/\1/; s/^[^=]+=([^" ]*).*/\1/'
}

# prompt_var FILE NAME "Question" [secret]
_prompt_var() {
  local file="$1" name="$2" question="$3" secret="${4:-}" current value
  current="$(_get_var "$file" "$name")"
  if [[ -n "$secret" ]]; then
    local shown="(empty)"
    [[ -n "$current" ]] && shown="(set - press Enter to keep)"
    read -rsp "  $question $shown: " value; echo
  else
    read -rp "  $question [${current}]: " value
  fi
  value="${value:-$current}"
  # escape for sed replacement
  local esc
  esc="$(printf '%s' "$value" | sed -e 's/[\\/&|]/\\&/g')"
  sed -i "s|^${name}=.*|${name}=\"${esc}\"|" "$file"
}

_ensure_generated() {
  local file="$1" name="$2" current
  current="$(_get_var "$file" "$name")"
  if [[ -z "$current" ]]; then
    sed -i "s|^${name}=.*|${name}=\"$(openssl rand -hex 16)\"|" "$file"
    ok "Generated a random $name"
  fi
}

t0_configure() {
  header "Configuration"
  [[ -f "$CONFIG_FILE" ]] || { cp "$ROOT/automation/config.env.example" "$CONFIG_FILE"; ok "Created automation/config.env"; }
  [[ -f "$SECRETS_FILE" ]] || { cp "$ROOT/automation/secrets.env.example" "$SECRETS_FILE"; ok "Created automation/secrets.env"; }
  chmod 600 "$SECRETS_FILE"

  info "Press Enter to keep the value shown in [brackets]."
  sub "GitHub / Docker Hub"
  _prompt_var "$CONFIG_FILE" GITHUB_USER "GitHub username"
  _prompt_var "$CONFIG_FILE" GITHUB_REPO "GitHub repository name"
  _prompt_var "$CONFIG_FILE" DOCKERHUB_USER "Docker Hub username"
  local dh_user
  dh_user="$(grep -E '^DOCKERHUB_USER=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"')"
  sed -i "s|^DOCKERHUB_REPO=.*|DOCKERHUB_REPO=\"${dh_user}/finsecure-pay\"|" "$CONFIG_FILE"

  sub "AWS / EKS"
  _prompt_var "$CONFIG_FILE" AWS_REGION "AWS region"
  _prompt_var "$CONFIG_FILE" EKS_INSTANCE_TYPE "Worker node instance type"
  _prompt_var "$CONFIG_FILE" EKS_SPOT "Use Spot instances to save cost (true/false)"

  sub "SonarQube Cloud"
  _prompt_var "$CONFIG_FILE" SONAR_ENABLED "Enable SonarQube Cloud quality gate (true/false)"
  _prompt_var "$CONFIG_FILE" SONAR_ORG "SonarQube Cloud organization key"
  _prompt_var "$CONFIG_FILE" SONAR_PROJECT_KEY "SonarQube Cloud project key"

  sub "Email notifications"
  _prompt_var "$CONFIG_FILE" SMTP_USER "Gmail address that SENDS notifications"
  _prompt_var "$CONFIG_FILE" NOTIFY_EMAIL "Email address that RECEIVES notifications"

  sub "Secrets (input is hidden; stored only in automation/secrets.env)"
  _prompt_var "$SECRETS_FILE" DOCKERHUB_TOKEN "Docker Hub access token" secret
  _prompt_var "$SECRETS_FILE" SONAR_TOKEN "SonarQube Cloud token" secret
  _prompt_var "$SECRETS_FILE" NVD_API_KEY "NVD API key" secret
  _prompt_var "$SECRETS_FILE" SMTP_PASSWORD "Gmail App Password (16 chars)" secret
  _ensure_generated "$SECRETS_FILE" JENKINS_ADMIN_PASSWORD
  _ensure_generated "$SECRETS_FILE" GRAFANA_ADMIN_PASSWORD
  _ensure_generated "$SECRETS_FILE" FINSECURE_API_KEY
  chmod 600 "$SECRETS_FILE"

  ok "Saved. Review anytime: automation/config.env (and secrets.env - keep private)."
  hint "Both files are listed in .gitignore and will never be committed."
}

t0_install_tools() {
  header "Install tools with Ansible"
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Tested on Ubuntu 24.04 - you are on ${PRETTY_NAME:-unknown}."
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    info "Installing Ansible (apt)..."
    run sudo apt-get update -y
    run sudo apt-get install -y ansible
  fi
  # deb822_repository needs ansible-core >= 2.15 (Ubuntu 24.04 ships 2.16; older releases need pipx)
  local core
  core="$(ansible --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)"
  if [[ "$(printf '%s\n2.15\n' "$core" | sort -V | head -n 1)" != "2.15" ]]; then
    warn "ansible-core $core is too old - installing a current version with pipx"
    run sudo apt-get install -y pipx
    run pipx install --include-deps ansible
    export PATH="$HOME/.local/bin:$PATH"
  fi
  info "You will be asked for your sudo password (BECOME password)."
  FINSECURE_USER="$(id -un)"; export FINSECURE_USER
  (cd "$ANSIBLE_DIR" && run ansible-playbook site.yml --tags base -K)
  ok "Tools installed."
  warn "If this was the first install, log out and back in (or run 'newgrp docker') so docker works without sudo."
}

t0_aws_login() {
  header "AWS credentials"
  load_config
  require_cmd aws
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    info "Enter the access key of an IAM user that can create EKS clusters (see README -> AWS account)."
    info "Region: ${AWS_REGION}   Output format: json"
    run aws configure --profile "$AWS_PROFILE"
  fi
  run aws sts get-caller-identity
  run aws configure set region "$AWS_REGION" --profile "$AWS_PROFILE"
  ok "AWS ready: account $(aws sts get-caller-identity --query Account --output text), region $AWS_REGION"
  warn "Create a budget alert now: https://console.aws.amazon.com/billing/home#/budgets (e.g. USD 60, email alerts)."
  hint "Credentials are stored in ~/.aws/credentials on this machine only - never in the repository."
}

t0_github_login() {
  header "GitHub login"
  load_config
  require_cmd gh git
  if ! gh auth status >/dev/null 2>&1; then
    info "Choose: GitHub.com -> HTTPS -> Yes (authenticate Git) -> Login with a web browser."
    run gh auth login --hostname github.com --git-protocol https --web
  fi
  run gh auth setup-git
  if [[ -z "$(git config --global user.name || true)" ]]; then
    local name email
    read -rp "  Your name for git commits: " name
    read -rp "  Your email for git commits: " email
    run git config --global user.name "$name"
    run git config --global user.email "$email"
  fi
  run git config --global init.defaultBranch main
  run gh auth status
  ok "GitHub ready."
}

t0_preflight() {
  header "Pre-flight check"
  local c fail=0
  for c in git java docker aws eksctl kubectl helm gh jq envsubst curl openssl; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c found"; else err "$c missing"; fail=1; fi
  done
  if command -v java >/dev/null 2>&1; then
    java -version 2>&1 | head -n 1 | grep -q '"21' && ok "Java 21" || { warn "Java 21 recommended"; }
  fi
  if docker info >/dev/null 2>&1; then ok "docker usable without sudo"; else warn "docker needs sudo - log out/in or 'newgrp docker'"; fi

  if [[ -f "$CONFIG_FILE" && -f "$SECRETS_FILE" ]]; then
    load_config
    ( require_vars GITHUB_USER DOCKERHUB_USER AWS_REGION SMTP_USER NOTIFY_EMAIL \
        DOCKERHUB_TOKEN NVD_API_KEY SMTP_PASSWORD JENKINS_ADMIN_PASSWORD FINSECURE_API_KEY ) \
      && ok "configuration complete" || fail=1
    if [[ "${SONAR_ENABLED:-true}" == "true" ]]; then
      ( require_vars SONAR_ORG SONAR_PROJECT_KEY SONAR_TOKEN ) && ok "SonarQube Cloud settings present" || fail=1
    fi
    local perms
    perms="$(stat -c %a "$SECRETS_FILE")"
    [[ "$perms" == "600" ]] && ok "secrets.env permissions 600" || warn "chmod 600 automation/secrets.env"
  else
    err "configuration missing (step 1)"; fail=1
  fi

  if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
    ok "AWS credentials valid ($(aws sts get-caller-identity --query Arn --output text))"
  else
    warn "AWS credentials not configured (step 3)"
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then ok "GitHub CLI logged in"; else warn "GitHub CLI not logged in (step 4)"; fi
  if git -C "$ROOT" check-ignore -q automation/secrets.env 2>/dev/null || grep -q '^automation/secrets.env' "$ROOT/.gitignore"; then
    ok "secrets.env is git-ignored"
  fi
  if ((fail == 0)); then ok "Ready."; else err "Fix the items above, then run this check again."; return 1; fi
}
