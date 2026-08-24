# fsamp-code-ci

Shared CI/CD for the FSAMP platform: reusable GitHub Actions workflows and
composite actions consumed by `fsamp-gateway`, `fsamp-processor`,
`fsamp-infra` and `fsamp-event-schema`. Pipeline logic lives here once and is
versioned like application code, so build, test, security scanning and release
behaviour stay consistent across repositories (NIST CM-2/CM-3).

## Reusable workflows

| Workflow | For | Pipeline |
|---|---|---|
| `build-java.yml` | Spring Boot services (gateway) | Maven build + JaCoCo gate, contract tests, SonarCloud, OWASP Dependency-Check, Semgrep, gitleaks, CycloneDX SBOM, Docker build (hadolint + Trivy), cosign sign + SBOM attestation, e2e, tag/release |
| `build-python.yml` | Python services (processor) | Ruff, pytest (coverage gate), contract tests, hash-pinned install, pip-audit/bandit, Semgrep, gitleaks, SBOM, Docker (hadolint + Trivy), cosign, e2e, tag/release |
| `build-terraform.yml` | IaC (infra) | fmt, validate, TFLint, Checkov, gitleaks, tag/release |
| `build-lite.yml` | Schema/library repos (event-schema) | versioning, gitleaks, publish, tag/release |
| `drift-detection.yml` | infra | scheduled `terraform plan -detailed-exitcode` per env; opens an issue on drift (CM-3/CM-6) |

Consumers call these with `workflow_call`, pinned to a release tag:

```yaml
jobs:
  ci:
    uses: pauszek/fsamp-code-ci/.github/workflows/build-java.yml@<release-tag>
    secrets: inherit
```

Per-repo behaviour is tuned with a `.github/params.yml` (java version, docker
on/off, sonar on/off, version file, release/publish flags).

## Security scanning

The pipeline is also a control gate. Tools are mapped to the NIST SP 800-53
families the project aligns with:

| Tool | Scope | Control |
|---|---|---|
| OWASP Dependency-Check / pip-audit | dependency CVEs (Java / Python) | RA-5, SI-2 |
| Semgrep CE (`p/security-audit` + language pack) | SAST on first-party code | SA-11 |
| gitleaks | secrets across full git history | IA-5(7), RA-5 |
| hadolint | Dockerfile hygiene | CM-6 |
| Trivy | container image CVEs | RA-5 |
| Checkov + TFLint | IaC misconfiguration | CM-6, SA-11 |
| SonarCloud | quality + security hotspots | SA-11 |

All gate Docker builds and releases (Semgrep/gitleaks at ERROR severity).
Scanner reports are uploaded as short-lived artifacts when a scanner fails, so
passing runs do not spend Actions storage on transfer evidence. Private repos
have no GitHub Advanced Security, so these run as first-class jobs rather than
relying on the Security tab.

Java scans restore the Dependency-Check data cache before updating it. A cold
cache is bootstrapped from the [Dependency-Check project's HTTPS data feed][nvd-feed]
instead of downloading the entire NVD catalog through the API. Warm-cache
updates use the API when `NVD_API_KEY` is available and the data feed otherwise.
Updates are enabled by default and respect `NVD_VALID_FOR_HOURS`; an internal
mirror can be selected with `NVD_DATAFEED_URL`, whose value must contain `{0}`.

[nvd-feed]: https://dependency-check.github.io/DependencyCheck/data/mirrornvd.html

## Supply chain

- **Actions pinned by commit SHA** — external and in-repo composite actions
  alike, so a pipeline run never depends on a moving `@main` (SR-11, SLSA
  source integrity).
- **Container images** signed keyless with cosign (Sigstore/Fulcio, GitHub
  OIDC); a CycloneDX SBOM is attached as an in-toto attestation and verified
  before deploy. Deploys resolve the tag to a `sha256` digest (SR-3/SR-4).
- **Python dependencies** install from a `--require-hashes` lockfile when the
  consumer provides one.

## Composite actions

`docker-build` (multi-arch build + cosign + SBOM), `security-scan` (Trivy),
`publish`, `run-e2e`, `tag-and-release`, `bump-release-version`.

`run-e2e` uses a same-named branch from `fsamp-infra` or the counterpart
service only while that branch has an open pull request to `main`. Stale
branches therefore cannot silently replace the current integration baseline.

> In-repo actions are referenced by full path at a pinned SHA
> (`pauszek/fsamp-code-ci/.github/actions/<name>@<sha>`) because reusable
> workflows resolve `./` against the *consumer's* checkout, not this repo. A
> change to an action therefore takes effect for consumers only after it is
> merged, tagged, and the workflow refs are re-pinned to the new SHA. For the
> same reason the gitleaks/Semgrep steps are inlined per workflow rather than
> extracted into a new action that would not yet exist at the pinned SHA.
> Hadolint is kept as an explicit workflow step before the Docker build so it
> remains visible in the job graph and gates the image before any BuildKit work.

## Release flow

Version is read from a `release.version` file. On merge to `main` the
`tag-and-release` action cuts a GitHub release + annotated tag, and
`bump-release-version` opens an auto-merge PR incrementing the patch.
