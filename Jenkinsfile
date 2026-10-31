// =============================================================================
// FinSecure Pay - CI/CD pipeline (Jenkins declarative pipeline)
//
//  Checkout -> Build -> Unit Test -> Package
//    -> Security: Code Quality (SonarQube Cloud quality gate)
//    -> Security: Dependency Scan (OWASP Dependency-Check, blocks CVSS >= 7)
//    -> Security: Secret Scan (Gitleaks, blocks any leaked credential)
//    -> Container Build -> Security: Image Scan (Trivy, blocks HIGH/CRITICAL)
//    -> Push (Docker Hub) -> Deploy (AWS EKS, automatic rollback) -> Smoke Test
//
// Any failed stage stops the pipeline, so a failing test or a security finding
// never reaches production. Environment values (DOCKERHUB_REPO, SONAR_ORG,
// SONAR_PROJECT_KEY, NOTIFY_EMAIL, SONAR_ENABLED) are Jenkins global variables set
// by Configuration-as-Code; secrets come only from the Jenkins credential store.
//
// Rollback: "Build with Parameters" and set ROLLBACK_TO_TAG to a known-good tag.
// =============================================================================
pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    // Checks GitHub for new commits every ~2 minutes - no inbound internet access to Jenkins needed
    triggers {
        pollSCM('H/2 * * * *')
    }

    parameters {
        string(name: 'ROLLBACK_TO_TAG', defaultValue: '',
               description: 'Rollback: redeploy an existing, previously scanned image tag (e.g. 1.0.0-b7-a1b2c3d). Leave empty for a normal build.')
    }

    environment {
        K8S_NAMESPACE  = 'finsecure'
        DEPLOYMENT     = 'finsecure-pay'
        TRIVY_IMAGE    = 'aquasec/trivy:0.76.1'
        GITLEAKS_IMAGE = 'zricethezav/gitleaks:v8.30.1'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'chmod +x mvnw'
                script {
                    env.GIT_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.APP_VERSION = sh(script: './mvnw -q -B -ntp help:evaluate -Dexpression=project.version -DforceStdout | tail -n 1',
                                         returnStdout: true).trim()
                    if (params.ROLLBACK_TO_TAG?.trim()) {
                        env.DEPLOY_MODE = 'rollback'
                        env.IMAGE_TAG = params.ROLLBACK_TO_TAG.trim()
                    } else {
                        env.DEPLOY_MODE = 'release'
                        env.IMAGE_TAG = "${env.APP_VERSION}-b${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    }
                    env.IMAGE = "${env.DOCKERHUB_REPO}:${env.IMAGE_TAG}"
                    currentBuild.description = "${env.DEPLOY_MODE}: ${env.IMAGE_TAG}"
                    echo "Mode=${env.DEPLOY_MODE} Version=${env.APP_VERSION} Image=${env.IMAGE}"
                }
            }
        }

        stage('Build') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                sh './mvnw -B -ntp clean compile'
            }
        }

        stage('Unit Test') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                sh './mvnw -B -ntp test'
            }
            post {
                always {
                    junit testResults: 'target/surefire-reports/*.xml', allowEmptyResults: false
                    publishHTML(target: [reportDir: 'target/site/jacoco', reportFiles: 'index.html',
                                         reportName: 'Code Coverage', keepAll: true,
                                         alwaysLinkToLastBuild: true, allowMissing: true])
                }
            }
        }

        stage('Package') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                sh './mvnw -B -ntp -DskipTests package'
                archiveArtifacts artifacts: 'target/finsecure-pay.jar', fingerprint: true
            }
        }

        stage('Security: Code Quality') {
            when {
                allOf {
                    environment name: 'DEPLOY_MODE', value: 'release'
                    not { environment name: 'SONAR_ENABLED', value: 'false' }
                }
            }
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    // qualitygate.wait=true makes the build FAIL if the SonarQube quality gate fails
                    sh '''
                        ./mvnw -B -ntp org.sonarsource.scanner.maven:sonar-maven-plugin:5.8.0.7211:sonar \
                          -Dsonar.host.url=https://sonarcloud.io \
                          -Dsonar.organization="$SONAR_ORG" \
                          -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
                          -Dsonar.qualitygate.wait=true \
                          -Dsonar.qualitygate.timeout=300
                    '''
                }
            }
        }

        stage('Security: Dependency Scan') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
                    // failBuildOnCVSS=7 is set in pom.xml: any High/Critical CVE fails this stage
                    sh './mvnw -B -ntp dependency-check:check'
                }
            }
            post {
                always {
                    publishHTML(target: [reportDir: 'target', reportFiles: 'dependency-check-report.html',
                                         reportName: 'Dependency-Check Report', keepAll: true,
                                         alwaysLinkToLastBuild: true, allowMissing: true])
                    archiveArtifacts artifacts: 'target/dependency-check-report.json', allowEmptyArchive: true
                }
            }
        }

        stage('Security: Secret Scan') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                // Scans the full git history; exit code 1 (= leak found) fails the stage
                sh '''
                    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
                      -v "$WORKSPACE:$WORKSPACE" -w "$WORKSPACE" "$GITLEAKS_IMAGE" \
                      git --redact --no-banner --report-format json --report-path "$WORKSPACE/gitleaks-report.json" "$WORKSPACE"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'gitleaks-report.json', allowEmptyArchive: true
                }
            }
        }

        stage('Container Build') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                sh '''
                    docker build --pull \
                      --build-arg APP_VERSION="$APP_VERSION" \
                      --build-arg GIT_COMMIT="$GIT_SHORT" \
                      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                      -t "$IMAGE" -t "$DOCKERHUB_REPO:$APP_VERSION" .
                    docker image ls "$DOCKERHUB_REPO"
                '''
            }
        }

        stage('Security: Image Scan') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                sh '''
                    TRIVY="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ -v $WORKSPACE:$WORKSPACE $TRIVY_IMAGE"
                    # 1) Full report of all severities, kept as build evidence
                    $TRIVY image --no-progress --scanners vuln --format table --output "$WORKSPACE/trivy-report.txt" "$IMAGE"
                    # 2) SECURITY GATE: fail on any fixable HIGH or CRITICAL vulnerability
                    #    Reviewed, time-limited exceptions live in .trivyignore (see docs/SECURITY-EXCEPTIONS.md)
                    $TRIVY image --no-progress --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
                      --ignorefile "$WORKSPACE/.trivyignore" --exit-code 1 "$IMAGE"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Push') {
            when { environment name: 'DEPLOY_MODE', value: 'release' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials',
                                                  usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
                        docker push "$IMAGE"
                        docker push "$DOCKERHUB_REPO:$APP_VERSION"
                        docker logout
                    '''
                }
            }
        }

        stage('Deploy to EKS') {
            steps {
                withCredentials([file(credentialsId: 'finsecure-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        set -eu
                        kubectl -n "$K8S_NAMESPACE" apply -f k8s/app/configmap.yaml -f k8s/app/service.yaml -f k8s/app/pdb.yaml

                        export BUILD_ID="$IMAGE_TAG"
                        export CHANGE_CAUSE="Jenkins #${BUILD_NUMBER} ${DEPLOY_MODE} ${IMAGE_TAG}"
                        export CONFIG_CHECKSUM="$(sha256sum k8s/app/configmap.yaml | cut -c1-16)"
                        envsubst '${IMAGE} ${BUILD_ID} ${CHANGE_CAUSE} ${CONFIG_CHECKSUM}' \
                          < k8s/app/deployment.yaml > rendered-deployment.yaml
                        kubectl -n "$K8S_NAMESPACE" apply -f rendered-deployment.yaml

                        # Wait for the rolling update. If the new pods never become Ready
                        # (failed readiness probe, crash, bad image) roll back automatically.
                        if ! kubectl -n "$K8S_NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=240s; then
                          echo "ROLLOUT FAILED - automatically rolling back to the previous version"
                          kubectl -n "$K8S_NAMESPACE" rollout undo deployment/"$DEPLOYMENT"
                          kubectl -n "$K8S_NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=240s
                          exit 1
                        fi
                        kubectl -n "$K8S_NAMESPACE" get deployment,pods -o wide
                        kubectl -n "$K8S_NAMESPACE" rollout history deployment/"$DEPLOYMENT" | tail -n 5
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                withCredentials([file(credentialsId: 'finsecure-kubeconfig', variable: 'KUBECONFIG'),
                                 string(credentialsId: 'finsecure-api-key', variable: 'API_KEY')]) {
                    sh '''
                        set -eu
                        # AWS load balancers expose a DNS hostname (other clouds an IP) - take whichever is set
                        IP=$(kubectl -n "$K8S_NAMESPACE" get svc finsecure-pay -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
                        echo "Service URL: http://$IP"

                        # Wait until the load balancer serves the build we just deployed
                        for i in $(seq 1 48); do
                          if curl -fsS --max-time 5 "http://$IP/health" -o health.json && grep -q "\\"build\\":\\"$IMAGE_TAG\\"" health.json; then
                            break
                          fi
                          sleep 5
                        done
                        cat health.json; echo
                        grep -q '"status":"UP"' health.json
                        grep -q "\\"build\\":\\"$IMAGE_TAG\\"" health.json

                        # Business check: one approved (200) and one rejected (422) transaction
                        APPROVED=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$IP/validate" \
                          -H 'Content-Type: application/json' -H "X-API-Key: $API_KEY" \
                          -d '{"transactionId":"SMOKE-OK","sourceAccount":"1234567890","destinationAccount":"9876543210","amount":10.00,"currency":"SGD"}')
                        REJECTED=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$IP/validate" \
                          -H 'Content-Type: application/json' -H "X-API-Key: $API_KEY" \
                          -d '{"transactionId":"SMOKE-REJECT","sourceAccount":"1234567890","destinationAccount":"9876543210","amount":999999,"currency":"SGD"}')
                        echo "approved=$APPROVED rejected=$REJECTED"
                        [ "$APPROVED" = "200" ] && [ "$REJECTED" = "422" ]
                    '''
                }
            }
            post {
                failure {
                    script {
                        if (env.DEPLOY_MODE == 'release') {
                            withCredentials([file(credentialsId: 'finsecure-kubeconfig', variable: 'KUBECONFIG')]) {
                                sh '''
                                    echo "SMOKE TEST FAILED - rolling back"
                                    kubectl -n "$K8S_NAMESPACE" rollout undo deployment/"$DEPLOYMENT"
                                    kubectl -n "$K8S_NAMESPACE" rollout status deployment/"$DEPLOYMENT" --timeout=240s
                                '''
                            }
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            emailext(
                to: "${env.NOTIFY_EMAIL}",
                mimeType: 'text/html',
                subject: "[SUCCESS] FinSecure Pay #${env.BUILD_NUMBER} deployed ${env.IMAGE_TAG}",
                body: """<p>Pipeline <b>${env.JOB_NAME} #${env.BUILD_NUMBER}</b> succeeded.</p>
                         <p>Mode: ${env.DEPLOY_MODE}<br/>Image: <code>${env.IMAGE}</code><br/>Commit: ${env.GIT_SHORT}</p>
                         <p><a href="${env.BUILD_URL}">Open build</a></p>""")
        }
        failure {
            emailext(
                to: "${env.NOTIFY_EMAIL}",
                mimeType: 'text/html',
                attachLog: true,
                subject: "[FAILED] FinSecure Pay #${env.BUILD_NUMBER} - deployment blocked",
                body: """<p>Pipeline <b>${env.JOB_NAME} #${env.BUILD_NUMBER}</b> FAILED. Nothing was deployed
                         (or the release was rolled back automatically).</p>
                         <p>Mode: ${env.DEPLOY_MODE}<br/>Image: <code>${env.IMAGE}</code><br/>Commit: ${env.GIT_SHORT}</p>
                         <p><a href="${env.BUILD_URL}console">Open console log</a> - the build log is attached.</p>""")
        }
        cleanup {
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
