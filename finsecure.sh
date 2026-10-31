#!/usr/bin/env bash
# =============================================================================
# FinSecure Pay - capstone automation menu
#
#   ./finsecure.sh              interactive menu
#   ./finsecure.sh 3            open the Task 3 menu
#   ./finsecure.sh 3 5          run Task 3, step 5 directly
#   ./finsecure.sh 3 all        run every step of Task 3 in order
#   ./finsecure.sh status       current state of everything
#   ./finsecure.sh help
#
# Output of every step is also saved to evidence/taskN/<timestamp>-<step>.log
# for screenshots and the final report.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT

# shellcheck source=automation/lib/common.sh
source "$ROOT/automation/lib/common.sh"
for _f in "$ROOT"/automation/lib/task[0-9]_*.sh; do
  # shellcheck source=/dev/null
  source "$_f"
done
unset _f

TASKS=(0 1 2 3 4 5 6 7)

# ----------------------------------------------------------------- step runner
# run_step TASK "num|title|function|capture"
run_step() {
  local task="$1" line="$2" num title fn cap log rc slug
  IFS='|' read -r num title fn cap <<<"$line"
  CURRENT_TASK="task${task}"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)"
  printf '\n%s\n' "${C_BOLD}>>> Task ${task} - step ${num}: ${title}${C_RESET}"
  set +e
  if [[ "$cap" == "yes" ]]; then
    mkdir -p "$EVIDENCE_DIR/$CURRENT_TASK"
    log="$EVIDENCE_DIR/$CURRENT_TASK/$(date +%Y%m%d-%H%M%S)-step${num}-${slug}.log"
    {
      echo "# FinSecure Pay | Task ${task} step ${num}: ${title}"
      echo "# $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname)"
    } > "$log"
    ( set -Eeuo pipefail; trap 'err "Failed: ${BASH_COMMAND} (line ${LINENO})"' ERR; "$fn" ) 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    sed -i 's/\x1b\[[0-9;]*m//g' "$log"
  else
    ( set -Eeuo pipefail; trap 'err "Failed: ${BASH_COMMAND} (line ${LINENO})"' ERR; "$fn" )
    rc=$?
  fi
  set -e
  if ((rc == 0)); then
    ok "Step ${num} complete${log:+ - evidence: ${log#"$ROOT"/}}"
  else
    err "Step ${num} failed (exit ${rc})${log:+ - see ${log#"$ROOT"/}}"
  fi
  return "$rc"
}

task_title() { local v="task${1}_title"; echo "${!v}"; }
task_steps() { "task${1}_steps"; }

task_menu() {
  local task="$1" choice line
  while true; do
    printf '\n%s\n' "${C_BOLD}${C_CYAN}Task ${task}: $(task_title "$task")${C_RESET}"
    while IFS='|' read -r num title _ _; do
      printf '  %2s) %s\n' "$num" "$title"
    done < <(task_steps "$task")
    printf '  %2s) %s\n   b) Back\n' "a" "Run all steps in order"
    read -rp "Select step: " choice || return 0
    case "$choice" in
      b|B|"") return 0 ;;
      a|A) run_all_steps "$task" || true ;;
      *)
        line="$(task_steps "$task" | awk -F'|' -v n="$choice" '$1 == n')"
        if [[ -n "$line" ]]; then run_step "$task" "$line" || true; pause
        else warn "Unknown step: $choice"; fi
        ;;
    esac
  done
}

run_all_steps() {
  local task="$1" line
  local -a lines=()
  mapfile -t lines < <(task_steps "$task")
  for line in "${lines[@]}"; do
    run_step "$task" "$line" || { err "Stopping: fix the failed step, then continue from there."; return 1; }
  done
}

# ----------------------------------------------------------------- status
show_status() {
  header "FinSecure Pay - status"
  if [[ ! -f "$CONFIG_FILE" ]]; then warn "Not configured yet - run ./finsecure.sh 0"; return 0; fi
  load_config
  printf '  %-18s %s\n' "App version" "$(app_version 2>/dev/null || echo '?')"
  printf '  %-18s %s\n' "Git" "$(git -C "$ROOT" log --oneline -n 1 2>/dev/null || echo 'not a repository yet')"
  if command -v aws >/dev/null 2>&1 && cluster_exists; then
    printf '  %-18s %s\n' "EKS cluster" "$EKS_CLUSTER ($(aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" --query 'cluster.[status,version]' --output text | tr '\t' ' '))"
    ensure_cluster_creds
    printf '  %-18s %s\n' "Nodes" "$(kubectl get nodes --no-headers 2>/dev/null | wc -l) ready"
    local ip
    ip="$(lb_address)"
    printf '  %-18s %s\n' "Pods ready" "$(kubectl -n "$FS_NS" get deploy "$FS_DEPLOY" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo '-')"
    printf '  %-18s %s\n' "Running image" "$(kubectl -n "$FS_NS" get deploy "$FS_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '-')"
    if [[ -n "$ip" ]]; then
      printf '  %-18s %s\n' "App URL" "http://$ip"
      printf '  %-18s %s\n' "/health" "$(curl -fsS --max-time 5 "http://$ip/health" 2>/dev/null || echo 'unreachable')"
    fi
    printf '  %-18s %s\n' "Monitoring" "$(helm status "$FS_MON_RELEASE" -n "$FS_MON_NS" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || echo 'not installed')"
  else
    printf '  %-18s %s\n' "EKS cluster" "not created"
  fi
  if jenkins_up; then
    local n
    n="$(jenkins_last_build)"
    printf '  %-18s %s\n' "Jenkins" "${JENKINS_URL} (last build #$n: $(jenkins_get "/job/${JENKINS_JOB}/lastBuild/api/json?tree=result" 2>/dev/null | jq -r '.result // "RUNNING"' 2>/dev/null || echo '-'))"
  else
    printf '  %-18s %s\n' "Jenkins" "not running"
  fi
}

usage() {
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo "Tasks:"
  local t
  for t in "${TASKS[@]}"; do printf '  %s  %s\n' "$t" "$(task_title "$t")"; done
}

main_menu() {
  local choice
  while true; do
    printf '\n%s\n' "${C_BOLD}${C_CYAN}FinSecure Pay - Cloud-Native DevOps Capstone${C_RESET}"
    local t
    for t in "${TASKS[@]}"; do
      if [[ "$t" == 0 ]]; then printf '  %s) %s\n' "$t" "$(task_title "$t")"
      else printf '  %s) Task %s - %s\n' "$t" "$t" "$(task_title "$t")"; fi
    done
    printf '  s) Status\n  h) Help\n  q) Quit\n'
    read -rp "Select: " choice || exit 0
    case "$choice" in
      [0-7]) task_menu "$choice" ;;
      s|S) ( show_status ) || true; pause ;;
      h|H) usage ;;
      q|Q) exit 0 ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
}

main() {
  case "${1:-}" in
    "") main_menu ;;
    help|-h|--help) usage ;;
    status) show_status ;;
    [0-7])
      local task="$1" step="${2:-}" line
      if [[ -z "$step" ]]; then task_menu "$task"
      elif [[ "$step" == "all" ]]; then run_all_steps "$task"
      else
        line="$(task_steps "$task" | awk -F'|' -v n="$step" '$1 == n')"
        [[ -n "$line" ]] || die "Task $task has no step $step"
        run_step "$task" "$line"
      fi
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
