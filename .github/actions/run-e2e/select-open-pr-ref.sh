#!/usr/bin/env bash
set -euo pipefail

repository="${1:-}"
candidate_ref="${2:-}"
default_ref="${3:-main}"

if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid GitHub repository: ${repository}" >&2
    exit 1
fi
if [[ -z "${default_ref}" ]]; then
    echo "Default ref must not be empty" >&2
    exit 1
fi

if [[ -z "${candidate_ref}" || "${candidate_ref}" == "${default_ref}" ]]; then
    printf '%s\n' "${default_ref}"
    exit 0
fi

owner="${repository%%/*}"
open_pr_count="$(
    gh api --method GET "repos/${repository}/pulls" \
        -f state=open \
        -f head="${owner}:${candidate_ref}" \
        -f base="${default_ref}" \
        --jq 'length'
)"

if [[ ! "${open_pr_count}" =~ ^[0-9]+$ ]]; then
    echo "GitHub returned an invalid open-PR count for ${repository}: ${open_pr_count}" >&2
    exit 1
fi

if ((open_pr_count > 0)); then
    printf '%s\n' "${candidate_ref}"
else
    printf '%s\n' "${default_ref}"
fi
