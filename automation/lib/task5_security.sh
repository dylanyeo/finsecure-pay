# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 5 - DevSecOps and security integration
# =============================================================================

task5_title="DevSecOps (security gates, blocked release, remediation, secrets)"
task5_steps() {
  cat <<'EOF'
1|Show the security controls and where each gate is configured|t5_overview|yes
2|Demo: add a vulnerable library -> security gate blocks the release|t5_inject_vuln|yes
3|Remediate: upgrade the library -> pipeline passes and deploys|t5_remediate|yes
4|Run the scanners locally (Trivy image + Gitleaks secrets) and save reports|t5_local_scans|yes
5|Evidence of secure secret and credential management|t5_secrets_evidence|yes
EOF
}

t5_overview() {
  header "Task 5 - Security controls"
  cat <<EOF
  Control                   Tool                      Gate (blocks the release when...)          Configured in
  ------------------------  ------------------------  -----------------------------------------  ------------------------------
  Code quality / SAST       SonarQube Cloud           quality gate fails (bugs, vulnerabilities, Jenkinsfile (qualitygate.wait)
                                                      coverage, security hotspots)
  Dependency scanning (SCA) OWASP Dependency-Check    any dependency with CVSS >= 7              pom.xml (failBuildOnCVSS)
  Secret scanning           Gitleaks                  a credential is found in the git history   Jenkinsfile (Secret Scan)
  Container image scanning  Trivy                     fixable HIGH or CRITICAL vulnerability     Jenkinsfile (Image Scan)
  Runtime hardening         Kubernetes                non-root, read-only FS, no privilege       k8s/app/deployment.yaml,
                                                      escalation, restricted Pod Security        k8s/base/namespace.yaml
  Least privilege           Kubernetes RBAC           Jenkins can only deploy in 'finsecure'     k8s/rbac/jenkins-deployer.yaml
  Secrets                   Jenkins credentials +     never in Git, images or logs               automation/ansible (JCasC),
                            Kubernetes Secrets                                                   Task 3 step 2
EOF
  sub "Gate settings in the code"
  run grep -n "failBuildOnCVSS" "$ROOT/pom.xml"
  run grep -n -E "qualitygate.wait|--exit-code 1|gitleaks" "$ROOT/Jenkinsfile"
}

t5_inject_vuln() {
  header "Task 5 - Vulnerable dependency is blocked"
  load_config
  _need_jenkins
  ensure_cluster_creds
  if grep -q "<artifactId>${VULN_LIB}</artifactId>" "$ROOT/pom.xml"; then
    warn "${VULN_LIB} is already in pom.xml"
  else
    python3 - "$ROOT/pom.xml" "$VULN_LIB" "$VULN_LIB_BAD" <<'PY'
import sys
path, lib, ver = sys.argv[1:4]
pom = open(path).read()
block = f"""        <!-- SECURITY DEMO: {lib} {ver} is affected by CVE-2022-42889 ("Text4Shell", CVSS 9.8) -->
        <dependency>
            <groupId>org.apache.commons</groupId>
            <artifactId>{lib}</artifactId>
            <version>{ver}</version>
        </dependency>
"""
pom = pom.replace("    </dependencies>", block + "    </dependencies>", 1)
open(path, "w").write(pom)
PY
  fi
  run git -C "$ROOT" --no-pager diff -- pom.xml
  local before prev n
  before="$(_running_image)"
  prev="$(jenkins_last_build)"
  git_commit_push "security demo: add ${VULN_LIB} ${VULN_LIB_BAD} (known critical CVE)" pom.xml
  n="$(jenkins_wait_new_build "$prev")"
  if jenkins_follow_build "$n"; then
    warn "Build passed - unexpected. Check the Dependency-Check report."
  else
    ok "BLOCKED at stage: $(jenkins_failed_stage "$n")"
  fi
  sub "Findings that triggered the gate"
  jenkins_get "/job/${JENKINS_JOB}/$n/consoleText" 2>/dev/null \
    | grep -E "CVE-2022-42889|One or more dependencies were identified|failBuildOnCVSS|CVSS score" | head -n 10 || true
  info "Running image unchanged: $(_running_image)"
  [[ "$before" == "$(_running_image)" ]] && ok "Vulnerable build never reached production."
  hint "Report: ${JENKINS_URL}job/${JENKINS_JOB}/$n/Dependency-Check_20Report/"
}

t5_remediate() {
  header "Task 5 - Remediation"
  load_config
  _need_jenkins
  if ! grep -q "<artifactId>${VULN_LIB}</artifactId>" "$ROOT/pom.xml"; then
    warn "${VULN_LIB} is not in pom.xml - nothing to remediate."
    return 0
  fi
  python3 - "$ROOT/pom.xml" "$VULN_LIB" "$VULN_LIB_BAD" "$VULN_LIB_FIXED" <<'PY'
import sys, re
path, lib, bad, fixed = sys.argv[1:5]
pom = open(path).read()
pom = pom.replace(f"<artifactId>{lib}</artifactId>\n            <version>{bad}</version>",
                  f"<artifactId>{lib}</artifactId>\n            <version>{fixed}</version>")
pom = re.sub(r"<!-- SECURITY DEMO: .*?-->", f"<!-- Remediated: upgraded {lib} {bad} -> {fixed} (fixes CVE-2022-42889) -->", pom)
open(path, "w").write(pom)
PY
  run git -C "$ROOT" --no-pager diff -- pom.xml
  local prev n
  prev="$(jenkins_last_build)"
  git_commit_push "fix(security): upgrade ${VULN_LIB} to ${VULN_LIB_FIXED} (CVE-2022-42889)" pom.xml
  n="$(jenkins_wait_new_build "$prev")"
  jenkins_follow_build "$n" && ok "Remediated build passed every gate and was deployed." || warn "Build failed - check the reports."
}

t5_local_scans() {
  header "Task 5 - Local security scans"
  load_config
  detect_docker
  local version out
  version="$(app_version)"
  out="$EVIDENCE_DIR/task5"
  mkdir -p "$out"
  sub "Trivy - container image $DOCKERHUB_REPO:$version"
  "${DOCKER[@]}" image inspect "$DOCKERHUB_REPO:$version" >/dev/null 2>&1 || dk pull "$DOCKERHUB_REPO:$version"
  dk run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ "$TRIVY_IMAGE" \
    image --no-progress --scanners vuln --format table "$DOCKERHUB_REPO:$version" | tee "$out/trivy-image-report.txt" | tail -n 25
  sub "Gitleaks - full git history"
  dk run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT:/repo" -w /repo "$GITLEAKS_IMAGE" \
    git --redact --no-banner -v /repo && ok "No secrets found in the git history"
  ok "Reports saved in evidence/task5/"
}

t5_secrets_evidence() {
  header "Task 5 - Secret and credential management"
  load_config
  cd "$ROOT" || return 1
  sub "Secret files are git-ignored (never committed)"
  run git check-ignore -v automation/secrets.env secrets/jenkins-kubeconfig.yaml || true
  sub "No secret values exist in tracked files"
  local k found=0
  for k in DOCKERHUB_TOKEN SONAR_TOKEN NVD_API_KEY SMTP_PASSWORD JENKINS_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD FINSECURE_API_KEY; do
    local v="${!k:-}"
    [[ -z "$v" ]] && continue
    if git grep -q -F -- "$v" 2>/dev/null; then err "$k value found in a tracked file!"; found=1
    else printf '  %-24s not present in repository\n' "$k"; fi
  done
  ((found == 0)) && ok "No secrets in source control."
  if jenkins_up; then
    sub "Jenkins credential store (IDs only - values are encrypted and never displayed)"
    jenkins_get "/credentials/store/system/domain/_/api/json?tree=credentials[id,typeName,description]" \
      | jq -r '.credentials[] | "  \(.id)\t\(.typeName)\t\(.description // "")"'
  fi
  if ensure_cluster_creds 2>/dev/null; then
    sub "Kubernetes Secrets (metadata only)"
    kc get secrets
    sub "The app receives the API key from a Secret reference, not a literal value"
    kubectl -n "$FS_NS" get deployment "$FS_DEPLOY" -o json \
      | jq '.spec.template.spec.containers[0].env[] | select(.name=="FINSECURE_APIKEY")'
    sub "Jenkins' Kubernetes identity cannot read Secrets"
    printf '  can-i get secrets (jenkins-deployer): %s\n' \
      "$(KUBECONFIG="$JENKINS_KUBECONFIG_FILE" kubectl auth can-i get secrets 2>/dev/null || true)"
  fi
}
