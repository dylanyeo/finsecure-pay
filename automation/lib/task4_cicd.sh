# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 4 - CI/CD pipeline automation (Jenkins)
# =============================================================================

task4_title="CI/CD with Jenkins (provision, pipeline, failing test, release, rollback)"
task4_steps() {
  cat <<'EOF'
1|Provision Jenkins with Ansible (plugins, credentials, pipeline job as code)|t4_provision|yes
2|Run the pipeline now and follow it|t4_run_pipeline|yes
3|Demo: a source-code change triggers the pipeline automatically|t4_change_trigger|yes
4|Demo: a failing unit test fails the pipeline and blocks deployment|t4_failing_test|yes
5|Remove the failing test (pipeline green again)|t4_fix_test|yes
6|Release a new version (minor bump) and verify the rollout|t4_release|yes
7|Rollback to a known-good version|t4_rollback|yes
8|Demo: broken release -> automatic rollback by the pipeline|t4_broken_release|yes
9|Restore a healthy release after the broken-release demo|t4_restore_release|yes
10|Show rollout history and recent pipeline runs|t4_history|yes
EOF
}

_need_jenkins() {
  jenkins_up || die "Jenkins is not reachable at ${JENKINS_LOCAL} - run step 1 first."
}

# Prints the image currently running in the cluster
_running_image() {
  kubectl -n "$FS_NS" get deployment "$FS_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

t4_provision() {
  header "Task 4 - Provision Jenkins"
  load_config
  require_vars GITHUB_USER DOCKERHUB_USER DOCKERHUB_REPO NOTIFY_EMAIL SMTP_USER SMTP_PASSWORD \
               NVD_API_KEY DOCKERHUB_TOKEN JENKINS_ADMIN_PASSWORD FINSECURE_API_KEY
  [[ "${SONAR_ENABLED:-true}" == "true" ]] && require_vars SONAR_ORG SONAR_PROJECT_KEY SONAR_TOKEN
  [[ -f "$JENKINS_KUBECONFIG_FILE" ]] || die "Missing Jenkins kubeconfig - run Task 3, step 2 first."
  require_cmd ansible-playbook

  ensure_cluster_creds
  local minor
  minor="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.major + "." + (.serverVersion.minor | gsub("[^0-9]"; ""))')"
  info "EKS control plane is v${minor} - Jenkins gets a matching kubectl."

  info "You will be asked for your sudo password (BECOME password)."
  (cd "$ANSIBLE_DIR" && run ansible-playbook site.yml --tags jenkins -K -e "kubectl_minor=${minor}")

  ok "Jenkins: ${JENKINS_URL}  (user: ${JENKINS_ADMIN_USER}, password: automation/secrets.env)"
  hint "Everything (plugins, credentials, email, the pipeline job) is defined as code:"
  hint "automation/ansible/roles/jenkins/templates/jenkins.yaml.j2 and files/plugins.txt"
}

t4_run_pipeline() {
  header "Task 4 - Run the pipeline"
  load_config
  _need_jenkins
  local prev n
  prev="$(jenkins_last_build)"
  info "Triggering ${JENKINS_JOB}..."
  jenkins_post "/job/${JENKINS_JOB}/build" >/dev/null
  n="$(jenkins_wait_new_build "$prev" 120)"
  jenkins_follow_build "$n" || true
  hint "First run downloads the OWASP vulnerability database (~10-20 min with an NVD API key). Later runs take ~5 min."
}

t4_change_trigger() {
  header "Task 4 - Source change triggers the pipeline"
  load_config
  _need_jenkins
  local prev n
  prev="$(jenkins_last_build)"
  mkdir -p "$ROOT/docs"
  printf -- '- %s: pipeline trigger demonstration (no code change)\n' "$(date '+%Y-%m-%d %H:%M')" >> "$ROOT/docs/CHANGELOG.md"
  git_commit_push "docs: update changelog (demonstrates automatic pipeline trigger)" docs/CHANGELOG.md
  n="$(jenkins_wait_new_build "$prev")"
  jenkins_follow_build "$n" || true
}

t4_failing_test() {
  header "Task 4 - Failing test blocks deployment"
  load_config
  _need_jenkins
  ensure_cluster_creds
  local before prev n stage
  before="$(_running_image)"
  info "Image running before the change: $before"
  local f="$ROOT/src/test/java/com/finsecure/pay/ControlledFailureTest.java"
  cat > "$f" <<'EOF'
package com.finsecure.pay;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/** Deliberately failing test: demonstrates that the pipeline stops before deployment. */
class ControlledFailureTest {

    @Test
    void controlledFailureForPipelineDemo() {
        assertThat(1 + 1).as("Controlled failure for the capstone demo").isEqualTo(3);
    }
}
EOF
  prev="$(jenkins_last_build)"
  git_commit_push "test: add controlled failing test (pipeline gate demo)" src/test/java/com/finsecure/pay/ControlledFailureTest.java
  n="$(jenkins_wait_new_build "$prev")"
  if jenkins_follow_build "$n"; then
    warn "The build passed - unexpected."
  else
    stage="$(jenkins_failed_stage "$n")"
    ok "Pipeline failed at stage: $stage"
  fi
  local after
  after="$(_running_image)"
  info "Image running after the failed build: $after"
  [[ "$before" == "$after" ]] && ok "Deployment did NOT change - the failing test blocked the release." \
                              || warn "Running image changed - investigate."
  hint "Next: step 5 removes the failing test."
}

t4_fix_test() {
  header "Task 4 - Remove the failing test"
  load_config
  _need_jenkins
  local prev n
  prev="$(jenkins_last_build)"
  (cd "$ROOT" && run git rm -q --ignore-unmatch src/test/java/com/finsecure/pay/ControlledFailureTest.java)
  (cd "$ROOT" && git diff --cached --quiet) && { warn "No failing test to remove."; return 0; }
  (cd "$ROOT" && run git commit -m "test: remove controlled failing test" && run git push origin HEAD:main)
  n="$(jenkins_wait_new_build "$prev")"
  jenkins_follow_build "$n" || true
}

t4_release() {
  header "Task 4 - Release a new version"
  load_config
  _need_jenkins
  ensure_cluster_creds
  local current next prev n ip
  current="$(app_version)"
  next="$(next_version "$current" minor)"
  info "Releasing $current -> $next"
  mkdir -p "$ROOT/docs"
  set_app_version "$next"
  printf -- '- %s: release %s\n' "$(date '+%Y-%m-%d %H:%M')" "$next" >> "$ROOT/docs/CHANGELOG.md"
  prev="$(jenkins_last_build)"
  git_commit_push "release: ${next}" pom.xml docs/CHANGELOG.md
  n="$(jenkins_wait_new_build "$prev")"
  jenkins_follow_build "$n" || die "Release build failed - see the console log."
  ip="$(app_host)"
  sub "Live version"
  wait_for_health "http://$ip" "\"version\":\"$next\""
  kc rollout history deployment/"$FS_DEPLOY"
  ok "Version $next is live with zero downtime (rolling update, maxUnavailable=0)."
}

t4_rollback() {
  header "Task 4 - Rollback to a known-good version"
  load_config
  ensure_cluster_creds
  local ip
  ip="$(app_host)"
  sub "Current state"
  run curl -s "http://$ip/health"; echo
  kc rollout history deployment/"$FS_DEPLOY"
  echo
  echo "  a) Kubernetes rollback  - 'kubectl rollout undo' to the previous ReplicaSet (seconds)"
  echo "  b) Pipeline rollback    - Jenkins redeploys a chosen, previously scanned image tag"
  local choice
  read -rp "Choose a or b [a]: " choice
  if [[ "${choice:-a}" == "b" ]]; then
    _need_jenkins
    sub "Recent image tags in Docker Hub"
    curl -s "https://hub.docker.com/v2/repositories/${DOCKERHUB_REPO}/tags?page_size=15&ordering=last_updated" \
      | jq -r '.results[].name' | grep -E -- '-b[0-9]+-' | head -n 10 | sed 's/^/  /'
    local tag prev n
    read -rp "Image tag to roll back to: " tag
    [[ -n "$tag" ]] || die "No tag entered."
    prev="$(jenkins_last_build)"
    jenkins_post "/job/${JENKINS_JOB}/buildWithParameters?ROLLBACK_TO_TAG=${tag}" >/dev/null
    n="$(jenkins_wait_new_build "$prev" 120)"
    jenkins_follow_build "$n" || die "Rollback build failed."
    wait_for_health "http://$ip" "\"build\":\"$tag\""
  else
    kc rollout undo deployment/"$FS_DEPLOY"
    kc rollout status deployment/"$FS_DEPLOY" --timeout=240s
    sleep 5
    run curl -s "http://$ip/health"; echo
  fi
  kc rollout history deployment/"$FS_DEPLOY"
  ok "Rolled back. Note: the next pipeline run deploys the latest commit again."
}

t4_broken_release() {
  header "Task 4 - Broken release is rolled back automatically"
  load_config
  _need_jenkins
  ensure_cluster_creds
  local before current next prev n ip
  before="$(_running_image)"
  current="$(app_version)"
  next="$(next_version "$current" patch)"
  info "Running now: $before"
  info "Creating release $next with readiness deliberately failing (finsecure.release.simulate-unhealthy=true)"
  sed -i 's/simulate-unhealthy: false/simulate-unhealthy: true/' "$ROOT/src/main/resources/application.yml"
  set_app_version "$next"
  prev="$(jenkins_last_build)"
  git_commit_push "release: ${next} (deliberately unhealthy - rollback demo)" pom.xml src/main/resources/application.yml
  n="$(jenkins_wait_new_build "$prev")"
  info "Expected: Deploy stage waits for readiness, times out (~4 min), runs 'rollout undo' and fails the build."
  if jenkins_follow_build "$n"; then
    warn "Build succeeded - unexpected."
  else
    ok "Pipeline failed at stage: $(jenkins_failed_stage "$n")"
  fi
  ip="$(app_host)"
  sub "Service is still answering with the previous healthy version"
  run curl -s "http://$ip/health"; echo
  info "Running after rollback: $(_running_image)"
  kc rollout history deployment/"$FS_DEPLOY"
  hint "Next: step 9 restores a healthy release."
}

t4_restore_release() {
  header "Task 4 - Restore a healthy release"
  load_config
  _need_jenkins
  local current next prev n ip
  sed -i 's/simulate-unhealthy: true/simulate-unhealthy: false/' "$ROOT/src/main/resources/application.yml"
  current="$(app_version)"
  next="$(next_version "$current" patch)"
  set_app_version "$next"
  prev="$(jenkins_last_build)"
  git_commit_push "release: ${next} (fix readiness)" pom.xml src/main/resources/application.yml
  n="$(jenkins_wait_new_build "$prev")"
  jenkins_follow_build "$n" || die "Build failed."
  ensure_cluster_creds
  ip="$(app_host)"
  wait_for_health "http://$ip" "\"version\":\"$next\""
}

t4_history() {
  header "Task 4 - History"
  load_config
  ensure_cluster_creds
  kc rollout history deployment/"$FS_DEPLOY"
  if jenkins_up; then
    sub "Recent pipeline runs"
    jenkins_get "/job/${JENKINS_JOB}/api/json?tree=builds[number,result,description,duration]{0,15}" \
      | jq -r '.builds[] | "  #\(.number)\t\(.result // "RUNNING")\t\((.duration/1000)|floor)s\t\(.description // "")"'
  fi
}
