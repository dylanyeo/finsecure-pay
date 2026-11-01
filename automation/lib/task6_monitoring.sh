# shellcheck shell=bash
# shellcheck disable=SC2034  # taskN_title and loop counters are read indirectly
# =============================================================================
# Task 6 - Monitoring, alerting and logging
# =============================================================================

task6_title="Monitoring, alerting & logging (Prometheus, Grafana, email, logs)"
task6_steps() {
  cat <<'EOF'
1|Install Prometheus, Grafana and Alertmanager (Helm) - ~5 minutes|t6_install|yes
2|Apply the app ServiceMonitor, alert rules and Grafana dashboard|t6_apply_app_monitoring|yes
3|Open the UIs (port-forward Grafana / Prometheus / Alertmanager)|t6_open_uis|yes
4|Generate normal traffic for the dashboard (10 minutes, background)|t6_traffic|yes
5|Trigger alert: high rejection rate -> email|t6_alert_rejections|yes
6|Trigger alert: fewer than 2 ready pods -> email|t6_alert_replicas|yes
7|Stop background traffic and port-forwards|t6_stop_background|yes
8|Enable centralised logging (CloudWatch Observability add-on)|t6_enable_cloudwatch|yes
9|Logs for troubleshooting (kubectl + CloudWatch Logs)|t6_logs|yes
EOF
}

_pf_pidfile() { echo "$SECRETS_DIR/port-forward.pids"; }

t6_install() {
  header "Task 6 - Install the monitoring stack"
  load_config
  require_vars SMTP_USER SMTP_PASSWORD NOTIFY_EMAIL GRAFANA_ADMIN_PASSWORD
  require_cmd helm
  ensure_cluster_creds
  kubectl create namespace "$FS_MON_NS" --dry-run=client -o yaml | kubectl apply -f - \
    || die "Could not create namespace $FS_MON_NS."

  sub "Secrets for Grafana admin and Alertmanager SMTP (from secrets.env)"
  kubectl -n "$FS_MON_NS" create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - || die "Could not create the Grafana admin Secret."
  kubectl -n "$FS_MON_NS" create secret generic alertmanager-smtp \
    --from-literal=password="$SMTP_PASSWORD" --dry-run=client -o yaml | kubectl apply -f - \
    || die "Could not create the Alertmanager SMTP Secret."
  run kubectl -n "$FS_MON_NS" get secrets grafana-admin alertmanager-smtp

  mkdir -p "$SECRETS_DIR"
  sed -e "s|SMTP_USER_PLACEHOLDER|${SMTP_USER}|g" -e "s|NOTIFY_EMAIL_PLACEHOLDER|${NOTIFY_EMAIL}|g" \
    "$ROOT/monitoring/kube-prometheus-stack-values.yaml" > "$SECRETS_DIR/kps-values.rendered.yaml"

  run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  run helm repo update prometheus-community
  run helm upgrade --install "$FS_MON_RELEASE" prometheus-community/kube-prometheus-stack \
    --version "$KPS_CHART_VERSION" --namespace "$FS_MON_NS" \
    -f "$SECRETS_DIR/kps-values.rendered.yaml" --wait --timeout 15m \
    || die "Helm install failed - see the error above (rerun this step; it is safe to repeat)."
  run kubectl -n "$FS_MON_NS" get pods
  ok "Monitoring stack installed."
}

t6_apply_app_monitoring() {
  header "Task 6 - App monitoring objects"
  load_config
  ensure_cluster_creds
  run kubectl apply -f "$ROOT/monitoring/servicemonitor.yaml" -f "$ROOT/monitoring/prometheusrule.yaml"
  kubectl -n "$FS_MON_NS" create configmap finsecure-dashboard \
    --from-file=finsecure-overview.json="$ROOT/monitoring/dashboards/finsecure-overview.json" \
    --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
  run kubectl -n "$FS_NS" get servicemonitor,prometheusrule
  sub "Alert rules"
  kubectl -n "$FS_NS" get prometheusrule finsecure-pay-alerts -o json \
    | jq -r '.spec.groups[].rules[] | "  \(.alert)  [\(.labels.severity)]  for \(.for)"'
  ok "Prometheus scrapes the app every 15 s; the dashboard appears in Grafana within ~1 minute."
}

t6_open_uis() {
  header "Task 6 - Monitoring UIs"
  load_config
  ensure_cluster_creds
  t6_stop_background >/dev/null 2>&1 || true
  mkdir -p "$SECRETS_DIR"
  local pidfile; pidfile="$(_pf_pidfile)"
  : > "$pidfile"
  nohup kubectl -n "$FS_MON_NS" port-forward --address 0.0.0.0 svc/${FS_MON_RELEASE}-grafana 3000:80 < /dev/null >/dev/null 2>&1 &
  echo $! >> "$pidfile"
  nohup kubectl -n "$FS_MON_NS" port-forward --address 0.0.0.0 svc/${FS_MON_RELEASE}-kube-prometheus-prometheus 9090:9090 < /dev/null >/dev/null 2>&1 &
  echo $! >> "$pidfile"
  nohup kubectl -n "$FS_MON_NS" port-forward --address 0.0.0.0 svc/${FS_MON_RELEASE}-kube-prometheus-alertmanager 9093:9093 < /dev/null >/dev/null 2>&1 &
  echo $! >> "$pidfile"
  sleep 4
  echo "  Grafana      : http://${JENKINS_HOST}:3000   (admin / GRAFANA_ADMIN_PASSWORD in secrets.env)"
  echo "                 Dashboard: Dashboards -> FinSecure Pay - Service Overview"
  echo "  Prometheus   : http://${JENKINS_HOST}:9090   (Status -> Targets, Alerts)"
  echo "  Alertmanager : http://${JENKINS_HOST}:9093"
  sub "Prometheus target health for the app"
  curl -s "http://127.0.0.1:9090/api/v1/targets?state=active" \
    | jq -r '.data.activeTargets[] | select(.labels.namespace=="finsecure") | "  \(.labels.pod)  \(.health)  \(.scrapeUrl)"' || true
  hint "Port-forwards run in the background; step 7 stops them."
}

# _traffic_loop URL MINUTES REJECT_PERCENT
_traffic_loop() {
  local url="$1" minutes="$2" reject_pct="$3" end i body code
  end=$(( $(date +%s) + minutes * 60 ))
  i=0
  while (( $(date +%s) < end )); do
    i=$((i + 1))
    if (( RANDOM % 100 < reject_pct )); then
      body="{\"transactionId\":\"LOAD-$i\",\"sourceAccount\":\"1234567890\",\"destinationAccount\":\"999999999999\",\"amount\":$((RANDOM % 30000)).00,\"currency\":\"JPY\"}"
    else
      body="{\"transactionId\":\"LOAD-$i\",\"sourceAccount\":\"1234567890\",\"destinationAccount\":\"9876543210\",\"amount\":$((RANDOM % 9000 + 1)).25,\"currency\":\"SGD\"}"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/validate" -H 'Content-Type: application/json' \
            -H "X-API-Key: $FINSECURE_API_KEY" -d "$body" || true)"
    curl -s -o /dev/null "$url/health" || true
    (( i % 50 == 0 )) && echo "[$(date +%H:%M:%S)] sent $i requests (last HTTP $code)"
    sleep 0.3
  done
}

t6_traffic() {
  header "Task 6 - Background traffic"
  load_config
  ensure_cluster_creds
  local ip; ip="$(app_host)"
  mkdir -p "$SECRETS_DIR"
  ( _traffic_loop "http://$ip" 10 15 ) < /dev/null > "$SECRETS_DIR/traffic.log" 2>&1 &
  echo $! > "$SECRETS_DIR/traffic.pid"
  ok "Sending ~3 requests/second (85% valid, 15% rejected) to http://$ip for 10 minutes."
  hint "Watch the Grafana dashboard fill up. Log: secrets/traffic.log"
}

_wait_alert() {
  local name="$1" timeout="${2:-480}" waited=0 state
  info "Waiting for Alertmanager to receive '$name' (rule 'for' + scrape + group_wait ~ 2-4 minutes)..."
  while ((waited < timeout)); do
    state="$(kubectl -n "$FS_MON_NS" exec "alertmanager-${FS_MON_RELEASE}-kube-prometheus-alertmanager-0" -c alertmanager -- \
             wget -qO- "http://localhost:9093/api/v2/alerts?filter=alertname%3D${name}" 2>/dev/null \
             | jq -r '.[0].status.state // empty' 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
      ok "ALERT FIRING: $name  ($(date +%H:%M:%S)) - Alertmanager is sending the email to ${NOTIFY_EMAIL}"
      kubectl -n "$FS_MON_NS" exec "alertmanager-${FS_MON_RELEASE}-kube-prometheus-alertmanager-0" -c alertmanager -- \
        wget -qO- "http://localhost:9093/api/v2/alerts?filter=alertname%3D${name}" 2>/dev/null \
        | jq '.[0] | {alert: .labels.alertname, severity: .labels.severity, startsAt, summary: .annotations.summary, description: .annotations.description}'
      return 0
    fi
    printf '  [%s] not firing yet...\n' "$(date +%H:%M:%S)"
    sleep 20; waited=$((waited + 20))
  done
  err "Alert did not fire within ${timeout}s - check Prometheus -> Alerts."
  return 1
}

t6_alert_rejections() {
  header "Task 6 - Alert: high rejection rate"
  load_config
  ensure_cluster_creds
  local ip; ip="$(app_host)"
  info "Sending a burst of invalid transactions (100% rejected) for 5 minutes in the background..."
  ( _traffic_loop "http://$ip" 5 100 ) < /dev/null > "$SECRETS_DIR/alert-traffic.log" 2>&1 &
  local tp=$!
  _wait_alert FinSecureHighRejectionRate 480 || true
  kill "$tp" 2>/dev/null || true
  ok "Check your inbox (${NOTIFY_EMAIL}) for '[FIRING] FinSecure Pay alert: FinSecureHighRejectionRate'."
  hint "A [RESOLVED] email follows a few minutes after the burst stops (send_resolved: true)."
}

t6_alert_replicas() {
  header "Task 6 - Alert: replicas unavailable"
  load_config
  ensure_cluster_creds
  info "Scaling the deployment to 1 replica to simulate losing a pod..."
  kc scale deployment/"$FS_DEPLOY" --replicas=1
  _wait_alert FinSecureReplicasUnavailable 420 || true
  info "Restoring 2 replicas..."
  kc scale deployment/"$FS_DEPLOY" --replicas=2
  kc rollout status deployment/"$FS_DEPLOY" --timeout=180s
  ok "Restored. A [RESOLVED] email follows shortly."
}

t6_stop_background() {
  header "Task 6 - Stop background jobs"
  local f pid
  for f in "$SECRETS_DIR/traffic.pid" "$(_pf_pidfile)"; do
    [[ -f "$f" ]] || continue
    while read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && echo "  stopped PID $pid"
    done < "$f"
    rm -f "$f"
  done
  pkill -f "port-forward --address 0.0.0.0 svc/${FS_MON_RELEASE}-" 2>/dev/null || true
  ok "Background traffic and port-forwards stopped."
}

t6_enable_cloudwatch() {
  header "Task 6 - Centralised logging with CloudWatch"
  load_config
  require_cmd aws eksctl
  ensure_cluster_creds
  warn "Container Insights adds small CloudWatch charges (log ingestion + metrics). Remove it at teardown."
  if aws eks describe-addon --cluster-name "$EKS_CLUSTER" --addon-name amazon-cloudwatch-observability \
       --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "Add-on already installed"
  else
    run aws eks create-addon --cluster-name "$EKS_CLUSTER" --addon-name amazon-cloudwatch-observability --region "$AWS_REGION"
  fi
  run aws eks wait addon-active --cluster-name "$EKS_CLUSTER" --addon-name amazon-cloudwatch-observability --region "$AWS_REGION"
  run kubectl -n amazon-cloudwatch get daemonsets
  ok "Fluent Bit now ships every container log to /aws/containerinsights/${EKS_CLUSTER}/application"
  hint "Node IAM permissions for this come from k8s/eks/cluster.yaml (withAddonPolicies.cloudWatch)."
}

t6_logs() {
  header "Task 6 - Logs for troubleshooting"
  load_config
  ensure_cluster_creds
  sub "1) Live application logs from all pods (structured JSON, ECS format)"
  kc logs -l app.kubernetes.io/name=finsecure-pay --prefix --tail=5
  sub "2) Find rejected transactions and the rule that rejected them"
  kubectl -n "$FS_NS" logs -l app.kubernetes.io/name=finsecure-pay --tail=500 2>/dev/null \
    | grep REJECTED | tail -n 5 | jq -r '"\(.["@timestamp"])  \(.message)"' 2>/dev/null || true
  sub "3) Logs of a container that crashed (previous instance)"
  hint "kubectl -n $FS_NS logs <pod> --previous"
  sub "4) Kubernetes events (scheduling, probe failures, restarts)"
  kubectl -n "$FS_NS" get events --sort-by=.lastTimestamp | tail -n 8
  sub "5) Centralised logs in Amazon CloudWatch (kept after pods are deleted)"
  local group="/aws/containerinsights/${EKS_CLUSTER}/application"
  if aws logs describe-log-groups --log-group-name-prefix "$group" --region "$AWS_REGION" \
       --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$group"; then
    run aws logs tail "$group" --region "$AWS_REGION" --since 1h --filter-pattern '"REJECTED"' --format short | tail -n 5 || true
  else
    warn "CloudWatch log group not found yet - run step 8 (enable the add-on) and wait ~2 minutes."
  fi
  echo
  echo "  CloudWatch Logs Insights: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:logs-insights"
  echo "  Example query (log group ${group}):"
  echo "    fields @timestamp, kubernetes.pod_name, log | filter kubernetes.namespace_name = \"finsecure\" and log like /REJECTED/ | sort @timestamp desc | limit 20"
}
