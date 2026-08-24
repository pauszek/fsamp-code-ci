#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="${repository_root}/.github/actions/run-e2e/select-open-pr-ref.sh"
test_directory="$(mktemp -d)"
fake_bin="${test_directory}/bin"
gh_calls="${test_directory}/gh-calls"

cleanup() {
    rm -rf "${test_directory}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"
cat > "${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_GH_CALLS}"
if [[ "${FAKE_GH_FAILURE:-false}" == "true" ]]; then
    exit 1
fi
printf '%s\n' "${FAKE_OPEN_PR_COUNT:?}"
EOF
chmod +x "${fake_bin}/gh"

export PATH="${fake_bin}:${PATH}"
export FAKE_GH_CALLS="${gh_calls}"

if [[ ! -f "${selector}" ]]; then
    echo "Missing E2E ref selector: ${selector}" >&2
    exit 1
fi

assert_ref() {
    local expected="$1"
    local repository="$2"
    local candidate="$3"
    local actual

    actual="$(bash "${selector}" "${repository}" "${candidate}")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "Expected ref ${expected}, got ${actual}" >&2
        exit 1
    fi
}

: > "${gh_calls}"
assert_ref main pauszek/fsamp-infra ""
if [[ -s "${gh_calls}" ]]; then
    echo "The selector must not call GitHub for an empty candidate ref" >&2
    exit 1
fi

export FAKE_OPEN_PR_COUNT=1
assert_ref feature/cross-repo pauszek/fsamp-infra feature/cross-repo
grep -Fq "repos/pauszek/fsamp-infra/pulls" "${gh_calls}"
grep -Fq "head=pauszek:feature/cross-repo" "${gh_calls}"
grep -Fq "base=main" "${gh_calls}"

export FAKE_OPEN_PR_COUNT=0
assert_ref main pauszek/fsamp-infra chore/autobump-0.0.30
assert_ref main pauszek/fsamp-processor chore/autobump-0.0.25

export FAKE_GH_FAILURE=true
if bash "${selector}" pauszek/fsamp-infra feature/api-failure >/dev/null 2>&1; then
    echo "The selector must fail closed when the GitHub query fails" >&2
    exit 1
fi

echo "E2E ref selection tests passed"
