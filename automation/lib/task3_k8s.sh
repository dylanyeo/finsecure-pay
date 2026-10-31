# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 3 - Kubernetes and cloud deployment (AWS EKS)
# =============================================================================

task3_title="Kubernetes on AWS EKS (cluster, deploy, external access, self-healing)"
task3_steps() {
  cat <<'EOF'
1|Create the EKS cluster (2 nodes, 2 AZs) - ~15-20 minutes|t3_create_cluster|yes
2|Create namespace, app Secret and least-privilege Jenkins identity|t3_bootstrap|yes
3|Deploy the app (ConfigMap, Deployment x2, Service/NLB, PDB) and test externally|t3_deploy|yes
4|Show deployment evidence (pods, probes, ConfigMap, Service)|t3_evidence|yes
5|Self-healing demo: delete a pod and watch Kubernetes recreate it|t3_delete_pod|yes
6|Self-healing demo: crash the app process and watch the container restart|t3_crash_container|yes
EOF
}

t3_create_cluster() {
  header "Task 3 - Create EKS cluster"
  load_config
  require_vars AWS_REGION EKS_CLUSTER EKS_VERSION EKS_INSTANCE_TYPE EKS_NODE_COUNT
  require_cmd aws eksctl kubectl envsubst
  mkdir -p "$SECRETS_DIR"
  envsubst '${EKS_CLUSTER} ${AWS_REGION} ${EKS_VERSION} ${EKS_INSTANCE_TYPE} ${EKS_SPOT} ${EKS_NODE_COUNT}' \
    < "$ROOT/k8s/eks/cluster.yaml" > "$SECRETS_DIR/eks-cluster.rendered.yaml"
  sub "Cluster definition (k8s/eks/cluster.yaml)"
  cat "$SECRETS_DIR/eks-cluster.rendered.yaml"
  if cluster_exists; then
    ok "Cluster $EKS_CLUSTER already exists"
  else
    warn "EKS costs about USD 0.10/hour for the control plane plus the EC2 nodes - see README (Cost)."
    info "Creating the cluster with eksctl (CloudFormation builds VPC, control plane and nodes: ~15-20 minutes)..."
    run eksctl create cluster -f "$SECRETS_DIR/eks-cluster.rendered.yaml"
  fi
  run aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --alias "$EKS_CLUSTER"
  run kubectl get nodes -o wide -L topology.kubernetes.io/zone
  run kubectl version
  ok "Cluster ready."
}

t3_bootstrap() {
  header "Task 3 - Namespace, Secret, Jenkins identity"
  load_config
  require_vars FINSECURE_API_KEY
  ensure_cluster_creds
  run kubectl apply -f "$ROOT/k8s/base/namespace.yaml"

  sub "Application Secret (API key) - created from secrets.env, never stored in Git"
  kubectl -n "$FS_NS" create secret generic finsecure-pay-secrets \
    --from-literal=api-key="$FINSECURE_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
  run kubectl -n "$FS_NS" get secret finsecure-pay-secrets

  sub "Least-privilege identity for Jenkins (namespace-scoped Role)"
  run kubectl apply -f "$ROOT/k8s/rbac/jenkins-deployer.yaml"
  local token="" i
  for i in $(seq 1 20); do
    token="$(kubectl -n "$FS_NS" get secret jenkins-deployer-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [[ -n "$token" ]] && break
    sleep 2
  done
  [[ -n "$token" ]] || die "Service account token was not created"

  local server ca
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  umask 077
  cat > "$JENKINS_KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: finsecure-eks
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: jenkins-deployer
    user:
      token: ${token}
contexts:
  - name: jenkins-deployer@finsecure
    context:
      cluster: finsecure-eks
      namespace: ${FS_NS}
      user: jenkins-deployer
current-context: jenkins-deployer@finsecure
EOF
  chmod 600 "$JENKINS_KUBECONFIG_FILE"
  ok "Jenkins kubeconfig written to secrets/jenkins-kubeconfig.yaml (git-ignored)"

  sub "Proof of least privilege (what Jenkins can and cannot do)"
  local q
  for q in "patch deployments" "create configmaps" "get pods" "get secrets" "delete namespaces" "create pods -n kube-system"; do
    # shellcheck disable=SC2086
    printf '  %-32s %s\n' "can-i $q" "$(KUBECONFIG="$JENKINS_KUBECONFIG_FILE" kubectl auth can-i $q 2>/dev/null || true)"
  done
}

t3_deploy() {
  header "Task 3 - Deploy to EKS"
  load_config
  require_vars DOCKERHUB_REPO FINSECURE_API_KEY
  ensure_cluster_creds
  local version image
  version="$(app_version)"
  image="docker.io/${DOCKERHUB_REPO}:${version}"
  info "Deploying image $image (pushed in Task 2)"

  kc apply -f "$ROOT/k8s/app/configmap.yaml" -f "$ROOT/k8s/app/service.yaml" -f "$ROOT/k8s/app/pdb.yaml"
  mkdir -p "$SECRETS_DIR"
  render_deployment "$image" "manual-${version}" "Manual deploy ${version} (Task 3)" > "$SECRETS_DIR/rendered-deployment.yaml"
  kc apply -f "$SECRETS_DIR/rendered-deployment.yaml"
  kc rollout status deployment/"$FS_DEPLOY" --timeout=300s
  kc get pods -o wide

  local ip
  ip="$(app_host)" || die "No load balancer address yet - run this step again in a minute."
  sub "External access through the AWS Network Load Balancer: http://$ip"
  wait_for_health "http://$ip"
  call_validate "http://$ip" "$TX_APPROVED" "$FINSECURE_API_KEY"
  call_validate "http://$ip" "$TX_REJECTED" "$FINSECURE_API_KEY"
  ok "Application is publicly reachable at http://$ip"
  echo "APP_URL=http://$ip" > "$SECRETS_DIR/app-url"
}

t3_evidence() {
  header "Task 3 - Deployment evidence"
  load_config
  ensure_cluster_creds
  kc get deployment,replicaset,pods,service,configmap,pdb -o wide
  sub "Readiness / liveness / startup probes"
  kubectl -n "$FS_NS" get deployment "$FS_DEPLOY" -o json \
    | jq '.spec.template.spec.containers[0] | {startupProbe, livenessProbe, readinessProbe}'
  sub "ConfigMap values"
  kc get configmap finsecure-pay-config -o yaml
  sub "Endpoints behind the Service (only Ready pods receive traffic)"
  kc get endpoints "$FS_SVC"
  sub "Replicas spread across nodes and availability zones"
  kubectl -n "$FS_NS" get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
  kubectl get nodes -L topology.kubernetes.io/zone
}

t3_delete_pod() {
  header "Task 3 - Self-healing: delete a pod"
  load_config
  ensure_cluster_creds
  kc get pods
  local pod
  pod="$(kubectl -n "$FS_NS" get pods -l app.kubernetes.io/name=finsecure-pay -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "No pods found - deploy first (step 3)."
  info "Deleting pod $pod at $(date +%H:%M:%S)"
  kc delete pod "$pod" --wait=false
  info "Watching for 45 seconds - a replacement pod is created immediately by the ReplicaSet:"
  timeout 45 kubectl -n "$FS_NS" get pods -l app.kubernetes.io/name=finsecure-pay -w || true
  kc get pods -o wide
  kc rollout status deployment/"$FS_DEPLOY" --timeout=180s
  sub "Recent events"
  kubectl -n "$FS_NS" get events --sort-by=.lastTimestamp | tail -n 12
  ok "Desired state restored: 2/2 pods running without manual intervention."
}

t3_crash_container() {
  header "Task 3 - Self-healing: crash the application process"
  load_config
  ensure_cluster_creds
  local pod
  pod="$(kubectl -n "$FS_NS" get pods -l app.kubernetes.io/name=finsecure-pay -o jsonpath='{.items[0].metadata.name}')"
  kc get pods
  info "Killing the Java process (PID 1) inside $pod"
  kc exec "$pod" -- kill 1 || true
  info "Watching for 60 seconds - the kubelet restarts the container (RESTARTS increases):"
  timeout 60 kubectl -n "$FS_NS" get pods -l app.kubernetes.io/name=finsecure-pay -w || true
  kc get pods
  ok "Container restarted automatically; the other replica kept serving traffic."
}
