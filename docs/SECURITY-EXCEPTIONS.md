# Security exceptions register

Findings that a security gate reported, that were reviewed, and that are accepted for a limited time.
Every entry has a reason, compensating controls, an owner and an expiry date. When an entry expires the
scanners report the finding again and the pipeline blocks the release until it is fixed or re-reviewed.

| ID | Finding | Component | Scanner severity | Decision | Expires |
|---|---|---|---|---|---|
| SEC-001 | CVE-2026-47884 - XsltView improper path limitation (SSRF/RCE) | spring-webmvc 6.2.19 | Trivy: CRITICAL (vendor: Medium) | Accepted - not exploitable | 2026-12-31 |
| SEC-002 | CVE-2026-47890 - SSE stream corruption while rendering fragments | spring-webmvc 6.2.19 | Trivy: CRITICAL | Accepted - not exploitable | 2026-12-31 |

| SEC-003 | 15 Spring Framework advisories (table below), reported by Dependency-Check against spring-core / spring-web | Spring Framework 6.2.19 | up to 9.8 | Accepted - feature not used | 2026-12-31 |
| SEC-004 | CVE-2026-42154 - Prometheus server remote-read DoS | micrometer-registry-prometheus (CPE mismatch) | 7.5 | False positive | 2026-12-31 |

## SEC-003 detail - Spring Framework 6.2.19 advisories

Dependency-Check matches every Spring jar to every Spring Framework CVE through the product CPE, so these appear
against spring-core and spring-web. Trivy, which matches exact artifacts, did not report them. Each was reviewed:

| CVE | Issue | CVSS | Why not reachable in FinSecure Pay |
|---|---|---|---|
| CVE-2026-47883 | Open redirect via broad UrlHandlerFilter patterns | below 7 | UrlHandlerFilter not configured |
| CVE-2026-47885 | WebFlux PartEventHttpMessageReader ignores maxPartSize | 7.5 | No WebFlux / multipart |
| CVE-2026-47886 | SpEL power operator DoS on user-supplied expressions | 7.5 | No SpEL evaluation of user input |
| CVE-2026-47887 | Open redirect in UrlFileNameViewController | 6.1 | No view controllers |
| CVE-2026-47888 | RSocket memory leak via malformed SETUP frame | 7.5 | No RSocket |
| CVE-2026-47889 | WebFlux on Jetty 12 omits SameSite on cookies | 7.5 | No WebFlux, no Jetty, no cookies |
| CVE-2026-47891 | WebFlux Aalto XML parsing ignores maxInMemorySize | 9.8 | No WebFlux, no XML input |
| CVE-2026-47892 | WebFlux functional endpoints header predicate bypass | 9.8 | No WebFlux functional endpoints |
| CVE-2026-47893 | WebFlux WebSocket leaks request headers in errors | 7.5 | No WebFlux / WebSocket |
| CVE-2026-59280 | FreeMarker template path traversal | 4.3 | No FreeMarker / views |
| CVE-2026-59281 | Reflected XSS when rendering field errors | 6.1 | No HTML rendering; JSON only |
| CVE-2026-59282 | DoS via user-supplied property paths in data binding | 7.5 | JSON bodies bound by Jackson; no request-parameter data binding |
| CVE-2026-59283 | SpEL SimpleEvaluationContext guard bypass with compiler on | 9.1 | No SpEL evaluation of user input |
| CVE-2026-59313 | SSE stream corruption in the functional web framework | 9.8 | No SSE, no functional routes |
| CVE-2026-59314 | Response splitting via Content-Disposition file names | 3.7 | No file downloads / Content-Disposition |

FinSecure Pay is a Spring MVC (servlet) service on Tomcat with two `@RestController` endpoints that read and write
JSON through Jackson. It has no WebFlux, RSocket, WebSocket, SSE, SpEL on input, server-side views or file downloads.

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
* Upgrade to Spring Boot 4.0.x (Spring Framework 7.0.9+) before 2026-12-31 and remove SEC-001 to SEC-003.
* Lesson: the Spring Framework 6.2 line no longer receives open-source fixes, so staying on it accumulates accepted risk. Framework lifecycle is a security requirement, not only a feature decision.

## Fixed instead of accepted

| Finding | Component | Fix |
|---|---|---|
| CVE-2026-89407, CVE-2026-89425 (HIGH, DoS) | jackson-core 2.21.4 | Upgraded to 2.21.7 (`jackson-bom.version` in pom.xml) |
| CVE-2026-68497, CVE-2026-91776, CVE-2026-91777 (HIGH, DoS) | jackson-databind 2.21.4 | Upgraded to 2.21.7 |
| CVE-2025-68161, CVE-2026-34477..34481, CVE-2026-49844 | log4j-api 2.24.3 | Upgraded to 2.25.5 (`log4j2.version` in pom.xml) |
