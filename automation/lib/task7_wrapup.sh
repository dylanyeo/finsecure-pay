# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 7 - Evidence, links, cost control and teardown
# =============================================================================

task7_title="Evidence, links, cost control & teardown"
task7_steps() {
  cat <<'EOF'
1|Write an evidence summary (links, versions, cluster state, pipeline runs)|t7_summary|yes
2|Show all project links for the presentation|t7_links|no
3|Pause to save money (scale nodes to 0)|t7_pause|yes
4|Resume (scale nodes back to 2)|t7_resume|yes
5|Teardown everything (delete monitoring, cluster, Jenkins container)|t7_teardown|yes
EOF
}

t7_links() {
  header "Project links"
  load_config
  local ip=""
  if cluster_exists; then
    ensure_cluster_creds
    ip="$(lb_address)"
  fi
  printf '  %-22s %s\n' "GitHub repository" "$GITHUB_WEB_URL"
  printf '  %-22s %s\n' "Docker Hub image" "$DOCKERHUB_WEB_URL"
  printf '  %-22s %s\n' "Application (public)" "${ip:+http://$ip/health}"
  printf '  %-22s %s\n' "Jenkins (private LAN)" "$JENKINS_URL"
  printf '  %-22s %s\n' "SonarQube Cloud" "https://sonarcloud.io/project/overview?id=${SONAR_PROJECT_KEY}"
  printf '  %-22s %s\n' "Grafana (port-forward)" "http://${JENKINS_HOST}:3000"
  printf '  %-22s %s\n' "EKS console" "https://${AWS_REGION}.console.aws.amazon.com/eks/home?region=${AWS_REGION}#/clusters/${EKS_CLUSTER}"
  hint "Only GitHub, Docker Hub, SonarQube Cloud and the app URL are reachable by the evaluator."
}

t7_summary() {
  header "Evidence summary"
  load_config
  local out="$EVIDENCE_DIR/SUMMARY.md"
  mkdir -p "$EVIDENCE_DIR"
  {
    echo "# FinSecure Pay - evidence summary ($(date '+%Y-%m-%d %H:%M %Z'))"
    echo
    echo "## Links"
    t7_links 2>/dev/null | sed -n '2,$p'
    echo
    echo "## Application version"
    echo "pom.xml version: $(app_version)"
    echo
    echo "## Git history (last 25 commits)"
    echo '```'
    git -C "$ROOT" log --oneline -n 25 2>/dev/null || true
    echo '```'
    if ensure_cluster_creds 2>/dev/null; then
      echo
      echo "## Kubernetes"
      echo '```'
      kubectl -n "$FS_NS" get deployment,pods,svc,configmap -o wide 2>/dev/null || true
      kubectl -n "$FS_NS" rollout history deployment/"$FS_DEPLOY" 2>/dev/null || true
      echo '```'
    fi
    if jenkins_up; then
      echo
      echo "## Recent pipeline runs"
      echo '```'
      jenkins_get "/job/${JENKINS_JOB}/api/json?tree=builds[number,result,description]{0,20}" \
        | jq -r '.builds[] | "#\(.number)\t\(.result // "RUNNING")\t\(.description // "")"' 2>/dev/null || true
      echo '```'
    fi
    echo
    echo "## Evidence logs"
    find "$EVIDENCE_DIR" -name '*.log' -printf '%P\n' 2>/dev/null | sort
  } > "$out"
  sed -i 's/\x1b\[[0-9;]*m//g' "$out"
  cat "$out"
  ok "Saved: evidence/SUMMARY.md"
}

t7_pause() {
  header "Pause (save cost)"
  load_config
  warn "Scaling nodes to 0 stops the app and monitoring and saves the EC2 cost."
  warn "The EKS control plane (USD 0.10/h) and the load balancer keep charging until teardown (step 5)."
  confirm "Scale the node group to 0?" || return 0
  run eksctl scale nodegroup --cluster "$EKS_CLUSTER" --region "$AWS_REGION" --name ng-default --nodes 0 --nodes-min 0
  ok "Paused. Resume with step 4."
}

t7_resume() {
  header "Resume"
  load_config
  run eksctl scale nodegroup --cluster "$EKS_CLUSTER" --region "$AWS_REGION" --name ng-default \
    --nodes "$EKS_NODE_COUNT" --nodes-min 0
  ensure_cluster_creds
  info "Waiting for pods to be scheduled again..."
  kubectl -n "$FS_NS" rollout status deployment/"$FS_DEPLOY" --timeout=600s || true
  kc get pods -o wide
}

t7_teardown() {
  header "Teardown"
  load_config
  warn "This deletes the EKS cluster, its VPC, nodes and load balancer, the CloudWatch add-on, and stops Jenkins."
  warn "Do this only AFTER your capstone has been graded."
  local answer
  read -rp "Type the cluster name ($EKS_CLUSTER) to confirm: " answer
  [[ "$answer" == "$EKS_CLUSTER" ]] || { info "Cancelled."; return 0; }
  if ensure_cluster_creds 2>/dev/null; then
    run helm uninstall "$FS_MON_RELEASE" -n "$FS_MON_NS" || true
    # Delete the Service first so AWS removes the load balancer; otherwise the VPC cannot be deleted
    run kubectl delete namespace "$FS_NS" --wait=true || true
    run aws eks delete-addon --cluster-name "$EKS_CLUSTER" --addon-name amazon-cloudwatch-observability --region "$AWS_REGION" || true
  fi
  run eksctl delete cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" --wait
  run aws logs delete-log-group --log-group-name "/aws/containerinsights/${EKS_CLUSTER}/application" --region "$AWS_REGION" || true
  run aws logs delete-log-group --log-group-name "/aws/containerinsights/${EKS_CLUSTER}/performance" --region "$AWS_REGION" || true
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx jenkins; then
    confirm "Also stop and remove the Jenkins container (data in /var/jenkins_home is kept)?" && run docker rm -f jenkins
  fi
  ok "Cloud resources deleted. Check https://console.aws.amazon.com/billing/home for any remaining charges."
}
