#!/usr/bin/env bash
set -euo pipefail

for workflow in build-java.yml build-python.yml; do
    workflow_path=".github/workflows/${workflow}"
    grep -q '^  quality-gate:' "${workflow_path}"
    grep -q 'needs: \[ params, quality-gate \]' "${workflow_path}"
    if grep -q '^  docker-push:' "${workflow_path}"; then
        echo "::error::${workflow} rebuilds an image after scanning"
        exit 1
    fi
    [[ "$(grep -c 'actions/docker-build@9dfa7ae8edd9017f3270f0d15db2aa3767d3a309' "${workflow_path}")" -eq 1 ]]
done

grep -q 'clean verify' .github/workflows/build-java.yml
grep -q -- '-P fips-tests' .github/workflows/build-java.yml
grep -q -- '-DfailIfNoTests=true' .github/workflows/build-java.yml
if grep -q -- '-Dgroups=fips' .github/workflows/build-java.yml; then
    echo "::error::The Java FIPS gate must activate the fail-closed fips-tests profile"
    exit 1
fi
grep -q 'python -m mypy src/' .github/workflows/build-python.yml

[[ "$(grep -Fc "client-id: \${{ vars.GABRBA_APPID }}" .github/workflows/build-java.yml)" -eq 3 ]]
[[ "$(grep -Fc "client-id: \${{ vars.GABRBA_APPID }}" .github/workflows/build-python.yml)" -eq 3 ]]
[[ "$(grep -Fc "app-id: \${{ vars.GABRBA_APPID }}" .github/workflows/build-java.yml)" -eq 1 ]]
[[ "$(grep -Fc "app-id: \${{ vars.GABRBA_APPID }}" .github/workflows/build-python.yml)" -eq 1 ]]
grep -Fq "client-id: \${{ inputs['app-id'] }}" \
    .github/actions/bump-release-version/action.yml

bump_action=.github/actions/bump-release-version/action.yml
grep -Fq "commit-message: \"chore: bump release.version to \${{ steps.bump.outputs.new }}\"" \
    "${bump_action}"
grep -Fq "title: \"[skip ci] chore: bump release.version to \${{ steps.bump.outputs.new }}\"" \
    "${bump_action}"
if grep -Fq 'commit-message: "[skip ci]' "${bump_action}"; then
    echo "::error::Autobump branch commits must run required pull-request checks"
    exit 1
fi
[[ "$(grep -c 'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25' \
    .github/actions/security-scan/action.yml)" -eq 2 ]]
for workflow in build-java.yml build-python.yml; do
    grep -q 'actions/security-scan@55fcc9152186ae32df127bab632a054b8f4f8aa3' \
        ".github/workflows/${workflow}"
done
for workflow in build-java.yml build-python.yml build-terraform.yml build-lite.yml; do
    grep -q 'actions/bump-release-version@8d702199082e5b694f1e015b0c99dba5d8b71a33' \
        ".github/workflows/${workflow}"
done

if grep -R -q 'REQUIRE_FIPS_PROVIDER=false' \
    .github/actions \
    .github/workflows/build-java.yml \
    .github/workflows/build-python.yml; then
    echo "::error::E2E must not disable the processor FIPS provider"
    exit 1
fi

grep -q 'Dockerfile.lambda' .github/actions/run-e2e/action.yml
grep -q 'enforce_fips(True)' .github/actions/run-e2e/action.yml

for workflow in build-java.yml build-python.yml; do
    workflow_path=".github/workflows/${workflow}"
    grep -q 'this-image:.*needs.docker-build.outputs.scan_ref' "${workflow_path}"
    [[ "$(grep -c 'actions/run-e2e@cad15e48d90cdb74ef335437c4c00434729bf8af' "${workflow_path}")" -eq 1 ]]
    [[ "$(grep -c 'name: Verify local scanned candidate' "${workflow_path}")" -eq 1 ]]
    [[ "$(grep -c 'name: Pull immutable scanned candidate' "${workflow_path}")" -eq 1 ]]
    grep -q 'SCAN_REF must be an immutable ghcr.io digest' "${workflow_path}"
    if grep -q '|| docker pull' "${workflow_path}"; then
        echo "::error::${workflow} may pull a mutable local candidate tag"
        exit 1
    fi
    if grep -q 'Build this service image' "${workflow_path}"; then
        echo "::error::${workflow} rebuilds the scanned image before E2E"
        exit 1
    fi
done

if grep -q 'drift.tfplan' .github/workflows/drift-detection.yml; then
    echo "::error::Binary Terraform plans must not be retained"
    exit 1
fi
grep -q 'plan-sanitized.txt' .github/workflows/drift-detection.yml
