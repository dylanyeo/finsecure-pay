# Security exceptions register

Findings that a security gate reported, that were reviewed, and that are accepted for a limited time.
Every entry has a reason, compensating controls, an owner and an expiry date. When an entry expires the
scanners report the finding again and the pipeline blocks the release until it is fixed or re-reviewed.

| ID | Finding | Component | Scanner severity | Decision | Expires |
|---|---|---|---|---|---|
| SEC-001 | CVE-2026-47884 - XsltView improper path limitation (SSRF/RCE) | spring-webmvc 6.2.19 | Trivy: CRITICAL (vendor: Medium) | Accepted - not exploitable | 2026-12-31 |
| SEC-002 | CVE-2026-47890 - SSE stream corruption while rendering fragments | spring-webmvc 6.2.19 | Trivy: CRITICAL | Accepted - not exploitable | 2026-12-31 |

## Why these are not exploitable here

* **SEC-001** requires a Spring MVC application that renders views with `XsltView` through a `/**` mapping
  without an explicit view name. FinSecure Pay renders no views at all: both endpoints return JSON from
  `@RestController` methods, and no `XsltView` or view resolver is configured.
* **SEC-002** requires view fragments streamed to clients over Server-Sent Events with attacker-controlled
  data. FinSecure Pay has no SSE endpoints.

## Why not fixed now

The open-source fix is only available in Spring Framework 7.0.9 (Spring Boot 4.x). The 6.2.x fix (6.2.20)
is distributed only through commercial support. Moving to Spring Boot 4 is a major upgrade (Jackson 3,
Jakarta and API changes) that needs its own regression cycle.

## Compensating controls

* Only `GET /health` and `POST /validate` are exposed through the load balancer; actuator is on an internal port.
* API key required on `/validate`; containers run as non-root with a read-only root filesystem.
* Remaining scanners (SonarQube, Gitleaks, Dependency-Check for all other CVEs) still gate every release.

## Remediation plan

* Owner: Yeo Yong Chang
* Upgrade to Spring Boot 4.0.x (Spring Framework 7.0.9+) before 2026-12-31 and remove both entries.

## Fixed instead of accepted

| Finding | Component | Fix |
|---|---|---|
| CVE-2026-89407, CVE-2026-89425 (HIGH, DoS) | jackson-core 2.21.4 | Upgraded to 2.21.7 (`jackson-bom.version` in pom.xml) |
| CVE-2026-68497, CVE-2026-91776, CVE-2026-91777 (HIGH, DoS) | jackson-databind 2.21.4 | Upgraded to 2.21.7 |
