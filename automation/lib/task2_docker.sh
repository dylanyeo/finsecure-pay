# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 2 - Containerisation
# =============================================================================

task2_title="Containerisation (build, run, test, tag, push)"
task2_steps() {
  cat <<'EOF'
1|Build the Docker image with a version tag|t2_build|yes
2|Run the container locally and test /health|t2_run|yes
3|Push the image to Docker Hub|t2_push|yes
4|Scan the image locally with Trivy (optional preview of the security gate)|t2_scan|yes
EOF
}

t2_build() {
  header "Task 2 - Build image"
  load_config
  require_vars DOCKERHUB_REPO
  detect_docker
  cd "$ROOT" || return 1
  local version sha
  version="$(app_version)"
  sha="$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)"
  info "Version from pom.xml: $version"
  dk build --pull \
    --build-arg APP_VERSION="$version" \
    --build-arg GIT_COMMIT="$sha" \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t "$DOCKERHUB_REPO:$version" -t "$DOCKERHUB_REPO:latest" . || die "Docker build failed - see the error above."
  sub "Image"
  dk image ls "$DOCKERHUB_REPO"
  sub "OCI labels (version metadata)"
  "${DOCKER[@]}" image inspect "$DOCKERHUB_REPO:$version" --format '{{json .Config.Labels}}' | jq .
  sub "Runs as non-root user"
  "${DOCKER[@]}" image inspect "$DOCKERHUB_REPO:$version" --format 'User: {{.Config.User}}'
  ok "Built $DOCKERHUB_REPO:$version"
}

t2_run() {
  header "Task 2 - Run container"
  load_config
  detect_docker
  local version name="finsecure-local"
  version="$(app_version)"
  "${DOCKER[@]}" rm -f "$name" >/dev/null 2>&1 || true
  dk run -d --name "$name" -p 8080:8080 -e FINSECURE_APIKEY=local-demo-key "$DOCKERHUB_REPO:$version"
  info "Waiting for the container health check to report 'healthy'..."
  local i status=""
  for i in $(seq 1 30); do
    status="$("${DOCKER[@]}" inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
    [[ "$status" == "healthy" ]] && break
    sleep 3
  done
  dk ps --filter "name=$name"
  sub "GET /health"
  run curl -s http://localhost:8080/health; echo
  sub "POST /validate (approved / rejected)"
  call_validate http://localhost:8080 "$TX_APPROVED" local-demo-key
  call_validate http://localhost:8080 "$TX_REJECTED" local-demo-key
  sub "Container logs"
  "${DOCKER[@]}" logs --tail 5 "$name"
  dk rm -f "$name" >/dev/null
  [[ "$status" == "healthy" ]] && ok "Container ran and reported healthy" || warn "Health status: ${status:-unknown}"
}

t2_push() {
  header "Task 2 - Push to Docker Hub"
  load_config
  require_vars DOCKERHUB_USER DOCKERHUB_REPO DOCKERHUB_TOKEN
  detect_docker
  local version
  version="$(app_version)"
  printf '%s\n' "${C_DIM}\$ echo \$DOCKERHUB_TOKEN | docker login -u $DOCKERHUB_USER --password-stdin${C_RESET}"
  printf '%s' "$DOCKERHUB_TOKEN" | "${DOCKER[@]}" login -u "$DOCKERHUB_USER" --password-stdin || die "Docker Hub login failed - check DOCKERHUB_USER and DOCKERHUB_TOKEN (0 -> 1)."
  dk push "$DOCKERHUB_REPO:$version" || die "Push failed."
  dk push "$DOCKERHUB_REPO:latest"
  dk logout
  sub "Registry check"
  local tags
  tags="$(curl -sL "https://hub.docker.com/v2/namespaces/${DOCKERHUB_USER}/repositories/finsecure-pay/tags?page_size=10" 2>/dev/null \
    | jq -r '.results[]? | "  \(.name)\t\(.last_updated)\t\((.full_size // 0) / 1048576 | floor) MB"' 2>/dev/null || true)"
  if [[ -n "$tags" ]]; then
    printf '%s\n' "$tags"
  else
    info "Docker Hub listing not available yet (new repository or rate limit) - check the page below in your browser."
  fi
  ok "Pushed: $DOCKERHUB_WEB_URL"
  hint "Pipeline builds use immutable tags: <version>-b<build>-<commit>, e.g. ${version}-b12-a1b2c3d"
}

t2_scan() {
  header "Task 2 - Trivy image scan (local)"
  load_config
  detect_docker
  local version
  version="$(app_version)"
  dk run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ -v "$ROOT/.trivyignore:/.trivyignore:ro" "$TRIVY_IMAGE" \
    image --no-progress --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --ignorefile /.trivyignore "$DOCKERHUB_REPO:$version"
  info "Accepted exceptions (not shown above, reviewed and time-limited): see .trivyignore and docs/SECURITY-EXCEPTIONS.md"
  ok "Scan finished (the pipeline fails the build if this table contains HIGH/CRITICAL findings)."
}
