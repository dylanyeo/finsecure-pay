# FinSecure Pay – Cloud-Native DevOps Pipeline

Transaction validation API for a fintech start-up, taken from source code to a production-style
deployment on Amazon EKS with a fully automated, security-gated CI/CD pipeline,
monitoring, alerting and centralised logging.

| Area | Implementation |
|---|---|
| Application | Spring Boot 3.5 (Java 21), Maven wrapper, `GET /health`, `POST /validate` |
| Tests | JUnit 5 unit tests + Spring Boot integration test, JaCoCo coverage |
| Container | Multi-stage Dockerfile, JRE-only Alpine runtime, non-root, health check, OCI labels |
| Registry | Docker Hub, immutable tags `<version>-b<build>-<commit>` |
| Kubernetes | Amazon EKS (eksctl, 2 nodes in 2 AZs), Deployment ×2, Network Load Balancer Service, ConfigMap, Secret, probes, PDB, restricted Pod Security |
| CI/CD | Jenkins (configuration as code), Jenkinsfile, polling trigger, automatic rollback, parameterised rollback |
| DevSecOps | SonarQube Cloud quality gate, OWASP Dependency-Check (CVSS ≥ 7 blocks), Gitleaks, Trivy (HIGH/CRITICAL blocks) |
| Secrets | Jenkins credential store (JCasC, read from files), Kubernetes Secrets, namespace-scoped RBAC for Jenkins |
| Monitoring | Prometheus, Grafana dashboard, Alertmanager email alerts (kube-prometheus-stack) |
| Logging | Structured JSON logs (Elastic Common Schema) → `kubectl logs` and Amazon CloudWatch Logs (Fluent Bit add-on) |
| Automation | `finsecure.sh` menu + Ansible roles: every task is reproducible |

```
 Developer ──git push──▶ GitHub ◀──poll── Jenkins (Docker, homelab VM)
                                            │ build ▸ test ▸ package ▸ Sonar ▸ Dependency-Check ▸ Gitleaks
                                            │ docker build ▸ Trivy ▸ push ──▶ Docker Hub
                                            ▼ deploy (namespace-scoped kubeconfig) ▸ smoke test / auto-rollback
                               ┌──────────── EKS cluster ─────────────┐
   Users ──HTTP──▶ AWS NLB  ──▶│ finsecure-pay pods ×2  (8080 API)     │
                               │        │ 8081 /actuator (internal)   │
                               │ Prometheus ◀─scrape   Grafana        │
                               │ Alertmanager ──email──▶ on-call      │
                               └──── stdout JSON logs ─▶ CloudWatch  ┘
```

## API

```bash
curl http://<NLB-DNS-NAME>/health
# {"status":"UP","service":"finsecure-pay","version":"1.0.0","build":"1.0.0-b5-a1b2c3d",...}

curl -X POST http://<NLB-DNS-NAME>/validate -H 'Content-Type: application/json' -H 'X-API-Key: <key>' \
  -d '{"transactionId":"TXN-1","sourceAccount":"1234567890","destinationAccount":"9876543210","amount":250.50,"currency":"SGD"}'
# 200 {"transactionId":"TXN-1","valid":true,"status":"APPROVED","violations":[]}
```

Validation rules (all evaluated, every failure reported): required fields, amount ≥ 0.01, amount ≤ limit
(`LIMIT_EXCEEDED`), max 2 decimal places, supported currency, account format, source ≠ destination,
blocked accounts, timestamp not in the future. Rejected transactions return **422** with the rule codes.
Limits, currencies and blocked accounts come from the Kubernetes ConfigMap.

## Prerequisites

**Control machine:** Ubuntu 24.04 x86_64 VM (4 vCPU, 8–12 GB RAM, 60 GB disk). It runs Jenkins and
all scripts. Do not use an ARM machine (images would not run on the x86 EKS nodes).

**Accounts (all free tiers):**

| Account | What to prepare |
|---|---|
| GitHub | Account; the repo is created public by the script |
| Docker Hub | Account settings → Personal access tokens → *Read & Write* token |
| AWS | Account with billing. Create an IAM user for the lab (AdministratorAccess is simplest; IAM Identity Center is better practice) and an access key for the CLI. **Create a budget alert first.** |
| SonarQube Cloud | Sign in with GitHub at sonarcloud.io, create an organisation, import the repo **after** Task 1. Then **Administration → Analysis Method → turn OFF Automatic Analysis** (CI analysis fails otherwise). Create a token (My Account → Security). |
| NVD | Free API key: nvd.nist.gov/developers/request-an-api-key (Dependency-Check is very slow without it) |
| Gmail | Turn on 2-Step Verification, then create an **App Password** for SMTP |

## Quick start

```bash
unzip finsecure-pay.zip && cd finsecure-pay
./finsecure.sh            # interactive menu
```

Work through the menu in order. Every step prints the exact commands it runs and saves its output to
`evidence/taskN/` for screenshots and the report.

| Menu | Steps |
|---|---|
| **0 Setup** | configuration prompts · install tools (Ansible) · AWS credentials · GitHub login · pre-flight check |
| **1 App & Git** | build + JUnit tests · run locally · create GitHub repo and push · git history |
| **2 Docker** | build versioned image · run + `/health` · push to Docker Hub · local Trivy scan |
| **3 EKS** | create cluster (eksctl) · namespace + Secret + Jenkins RBAC · deploy + external test · evidence · delete-pod demo · crash demo |
| **4 CI/CD** | provision Jenkins · run pipeline · change triggers pipeline · failing test blocks deploy · fix · release new version · rollback · broken release auto-rollback · restore · history |
| **5 DevSecOps** | controls overview · vulnerable library blocked · remediation · local scans · secrets evidence |
| **6 Monitoring** | install Prometheus/Grafana/Alertmanager · ServiceMonitor + alerts + dashboard · open UIs · traffic · rejection-rate alert · replica alert · stop · CloudWatch logging · logs |
| **7 Wrap-up** | evidence summary · links · pause/resume nodes · teardown |

Non-interactive: `./finsecure.sh 3 5` runs Task 3 step 5; `./finsecure.sh 4 all` runs all of Task 4; `./finsecure.sh status`.

## Repository layout

```
src/                      Spring Boot application and tests
pom.xml, mvnw, .mvn/      Maven build (wrapper pins Maven 3.9.16)
Dockerfile                multi-stage container build
Jenkinsfile               CI/CD pipeline
k8s/                      eksctl cluster definition, namespace, ConfigMap, Deployment, Services, PDB, Jenkins RBAC
monitoring/               Helm values, ServiceMonitor, alert rules, Grafana dashboard
dependency-check-suppressions.xml   reviewed false positives (with expiry dates)
finsecure.sh              task menu
automation/lib/           one script per capstone task
automation/ansible/       control-machine provisioning and Jenkins configuration as code
automation/*.example      configuration templates (real config.env / secrets.env are git-ignored)
```

## Security design

* Secrets live only in `automation/secrets.env` (chmod 600, git-ignored), the Jenkins credential store
  and Kubernetes Secrets. Jenkins reads them from read-only files, never from the YAML or environment.
* Jenkins deploys with a namespace-scoped service account: it can update the app in `finsecure` but
  cannot read Secrets or touch any other namespace (`./finsecure.sh 3 2` prints the proof).
* Pods run as non-root with a read-only root filesystem, no privilege escalation, all capabilities
  dropped and the *restricted* Pod Security Standard enforced on the namespace.
* Actuator (probes, metrics) listens on an internal port that the load balancer never exposes.
* Four release gates: quality gate, dependency CVEs (CVSS ≥ 7), leaked secrets, image CVEs (HIGH/CRITICAL).

## Cost and clean-up

AWS charges for the EKS control plane (USD 0.10/hour, no free tier), two t3.large nodes, their disks
and one Network Load Balancer. Rough Singapore on-demand estimate: **about USD 8 per day with
everything running**, about **USD 3 per day with nodes paused** (control plane + NLB still charge).
Setting `EKS_SPOT="true"` cuts the node cost by roughly 60–70%. No NAT gateway is created
(saves ~USD 1.50/day). Check current prices with the AWS Pricing Calculator.

* **7 → 3 (pause)** scales nodes to 0 overnight; **7 → 4** resumes.
* **7 → 5 (teardown)** after grading deletes the load balancer, the cluster, its VPC (via
  CloudFormation) and the CloudWatch log groups. Then check *Billing → Bills* for leftovers.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied ... docker.sock` | Log out and in again (or `newgrp docker`) after Task 0 step 2 |
| Sonar stage: *"automatic analysis is enabled"* | SonarQube Cloud → project → Administration → Analysis Method → disable Automatic Analysis |
| First Dependency-Check run is slow | Normal: it downloads the NVD database (10–20 min with an API key). Later runs reuse the cache. |
| Dependency-Check blocks a clean build | Read the report. Upgrade the library, or add a reviewed suppression with an expiry date. |
| Jenkins does not start a build after a push | Polling runs every ~2 min; check *Git Polling Log* on the job page |
| No load balancer address / DNS does not resolve | AWS needs 2–4 minutes to create the NLB and publish its DNS name; the scripts wait, or run the step again |
| `eksctl create cluster` fails half way | Read the CloudFormation error in the AWS console (often a service quota or permissions); `eksctl delete cluster -f ...` then retry |
| Alert email not received | Check spam; verify the Gmail App Password; Alertmanager UI → Status |
