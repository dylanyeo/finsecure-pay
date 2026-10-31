# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 1 - Application development and version control
# =============================================================================

task1_title="Application & Git (build, test, run, push to GitHub)"
task1_steps() {
  cat <<'EOF'
1|Build and run the JUnit 5 unit tests|t1_build_test|yes
2|Run the app locally and call /health and /validate|t1_run_local|yes
3|Create the GitHub repository and push (logical commit history)|t1_push_github|yes
4|Show git history and repository link|t1_git_log|yes
EOF
}

t1_build_test() {
  header "Task 1 - Build and unit tests"
  require_cmd java
  cd "$ROOT" || return 1
  chmod +x mvnw
  run ./mvnw -B -ntp clean verify

  sub "Test summary (target/surefire-reports)"
  local tests=0 failures=0 errors=0 skipped=0 f
  for f in target/surefire-reports/TEST-*.xml; do
    [[ -f "$f" ]] || continue
    local line
    line="$(grep -m1 -o '<testsuite[^>]*>' "$f")"
    tests=$((tests + $(sed -E 's/.* tests="([0-9]+)".*/\1/' <<<"$line")))
    failures=$((failures + $(sed -E 's/.* failures="([0-9]+)".*/\1/' <<<"$line")))
    errors=$((errors + $(sed -E 's/.* errors="([0-9]+)".*/\1/' <<<"$line")))
    skipped=$((skipped + $(sed -E 's/.* skipped="([0-9]+)".*/\1/' <<<"$line")))
    printf '  %-70s %s\n' "$(basename "$f" .xml | sed 's/^TEST-//')" "$(sed -E 's/.* tests="([0-9]+)".*/\1/' <<<"$line") tests"
  done
  echo "  ------------------------------------------------------------------"
  echo "  Total: $tests tests, $failures failures, $errors errors, $skipped skipped"

  if [[ -f target/site/jacoco/jacoco.csv ]]; then
    awk -F, 'NR>1 {missed+=$8; covered+=$9} END {if (missed+covered>0) printf "  Line coverage (JaCoCo): %.1f%%\n", 100*covered/(missed+covered)}' target/site/jacoco/jacoco.csv
  fi
  ok "Build artifact: target/finsecure-pay.jar ($(du -h target/finsecure-pay.jar | cut -f1))"
  hint "HTML reports: target/site/jacoco/index.html (coverage)"
}

t1_run_local() {
  header "Task 1 - Run locally"
  cd "$ROOT" || return 1
  [[ -f target/finsecure-pay.jar ]] || run ./mvnw -B -ntp -q -DskipTests package
  info "Starting the application on http://localhost:8080 (management port 8081)..."
  FINSECURE_APIKEY="local-demo-key" java -jar target/finsecure-pay.jar > target/local-run.log 2>&1 &
  local pid=$!
  trap 'kill $pid 2>/dev/null || true' RETURN
  local i
  for i in $(seq 1 60); do
    curl -fsS http://localhost:8080/health >/dev/null 2>&1 && break
    sleep 1
  done

  sub "GET /health"
  run curl -s http://localhost:8080/health; echo
  sub "POST /validate - valid transaction (expect 200 APPROVED)"
  call_validate http://localhost:8080 "$TX_APPROVED" local-demo-key
  sub "POST /validate - invalid transaction (expect 422 REJECTED with reasons)"
  call_validate http://localhost:8080 "$TX_REJECTED" local-demo-key
  sub "POST /validate - missing API key (expect 401)"
  call_validate http://localhost:8080 "$TX_APPROVED"
  sub "Readiness probe and metrics (management port 8081)"
  run curl -s http://localhost:8081/actuator/health/readiness; echo
  run bash -c "curl -s http://localhost:8081/actuator/prometheus | grep '^finsecure_validations_total'"
  sub "Application log (JSON, Elastic Common Schema)"
  tail -n 3 target/local-run.log
  ok "Local run verified - stopping the application."
}

t1_push_github() {
  header "Task 1 - GitHub repository"
  load_config
  require_vars GITHUB_USER GITHUB_REPO
  require_cmd git gh
  cd "$ROOT" || return 1

  if [[ ! -d .git ]]; then
    run git init -b main
    # Logical commits so the history explains how the project is built up
    _commit() { local msg="$1"; shift; local p existing=(); for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
                ((${#existing[@]})) || return 0; run git add -- "${existing[@]}"
                git diff --cached --quiet || run git commit -m "$msg"; }
    _commit "chore: project scaffold - Spring Boot 3.5, Java 21, Maven wrapper" \
      pom.xml mvnw mvnw.cmd .mvn .gitignore .gitattributes
    _commit "feat: /health and /validate endpoints with transaction validation rules" src/main
    _commit "test: JUnit 5 unit tests and Spring Boot integration test" src/test
    _commit "build: multi-stage Dockerfile running as a non-root user" Dockerfile .dockerignore
    _commit "deploy: Kubernetes manifests - 2 replicas, probes, ConfigMap, PDB, least-privilege Jenkins RBAC" k8s
    _commit "ci: Jenkins pipeline with security gates, auto-rollback and email notifications" \
      Jenkinsfile dependency-check-suppressions.xml
    _commit "ops: Prometheus alert rules, ServiceMonitor and Grafana dashboard" monitoring
    _commit "chore: automation (finsecure.sh + Ansible) and documentation" \
      finsecure.sh automation README.md docs
    _commit "chore: remaining project files" .
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    if gh repo view "$GITHUB_USER/$GITHUB_REPO" >/dev/null 2>&1; then
      run git remote add origin "$GITHUB_REPO_URL"
    else
      run gh repo create "$GITHUB_USER/$GITHUB_REPO" --public \
        --description "FinSecure Pay - cloud-native transaction validation API (DevOps capstone)" \
        --source . --remote origin
    fi
  fi
  run git push -u origin main
  ok "Pushed: $GITHUB_WEB_URL"
  hint "The repository must stay PUBLIC so the evaluator and SonarQube Cloud can access it."
}

t1_git_log() {
  header "Task 1 - Git history"
  load_config
  ensure_git_repo
  cd "$ROOT" || return 1
  run git log --oneline --graph --decorate -n 30
  run git remote -v
  ok "Repository: $GITHUB_WEB_URL"
}
