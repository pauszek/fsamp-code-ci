#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${MODE:-dry-run}"
OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-pauszek}}"
TARGET_REPOS="${TARGET_REPOS:-}"
ARTIFACT_RETENTION_DAYS="${ARTIFACT_RETENTION_DAYS:-14}"
CACHE_RETENTION_DAYS="${CACHE_RETENTION_DAYS:-7}"
CACHE_MAX_BYTES="${CACHE_MAX_BYTES:-1073741824}"
DOCKER_IMAGE_MAX_AGE_HOURS="${DOCKER_IMAGE_MAX_AGE_HOURS:-6}"
INCLUDE_PACKAGES="${INCLUDE_PACKAGES:-false}"
PACKAGE_MODE="${PACKAGE_MODE:-dry-run}"
PACKAGE_RETENTION_DAYS="${PACKAGE_RETENTION_DAYS:-$ARTIFACT_RETENTION_DAYS}"
PACKAGE_OWNER_KIND="${PACKAGE_OWNER_KIND:-user}"
PACKAGE_CLEANUP_TOKEN="${PACKAGE_CLEANUP_TOKEN:-${FSAMP_PACKAGE_CLEANUP_TOKEN:-}}"

artifact_deleted=0
artifact_bytes=0
cache_deleted=0
cache_bytes=0
package_deleted=0

die() {
  echo "::error::$*" >&2
  exit 1
}

log() {
  echo "$*"
}

validate_mode() {
  local value="$1"
  local name="$2"
  case "$value" in
    dry-run | apply) ;;
    *) die "$name must be 'dry-run' or 'apply' (got '$value')" ;;
  esac
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

iso_to_epoch() {
  python3 - "$1" <<'PY'
from datetime import datetime, timezone
import sys

value = sys.argv[1].replace("Z", "+00:00")
print(int(datetime.fromisoformat(value).astimezone(timezone.utc).timestamp()))
PY
}

now_epoch() {
  date -u +%s
}

normalize_bool() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true | 1 | yes | y) echo "true" ;;
    *) echo "false" ;;
  esac
}

api_delete() {
  local path="$1"
  if [[ "$MODE" == "apply" ]]; then
    gh api -X DELETE "$path" >/dev/null
  fi
}

package_api() {
  if [[ -n "$PACKAGE_CLEANUP_TOKEN" ]]; then
    GH_TOKEN="$PACKAGE_CLEANUP_TOKEN" gh api "$@"
  else
    gh api "$@"
  fi
}

package_base_path() {
  if [[ "$PACKAGE_OWNER_KIND" == "org" ]]; then
    printf '/orgs/%s/packages' "$OWNER"
  else
    printf '/users/%s/packages' "$OWNER"
  fi
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

discover_repos() {
  if [[ -n "$TARGET_REPOS" ]]; then
    printf '%s\n' "$TARGET_REPOS" \
      | tr ',;' '\n' \
      | awk 'NF {print $1}' \
      | while read -r repo; do
          if [[ "$repo" == */* ]]; then
            printf '%s\n' "$repo"
          else
            printf '%s/%s\n' "$OWNER" "$repo"
          fi
        done
    return
  fi

  if gh repo list "$OWNER" --limit 200 --json nameWithOwner \
      --jq '.[] | select(.nameWithOwner | test("/fsamp-")) | .nameWithOwner' 2>/dev/null | sort -u; then
    return
  fi

  local repo
  for repo in fsamp-code-ci fsamp-gateway fsamp-processor fsamp-infra \
    fsamp-event-schema fsamp-demo-flow fsamp-thesis fsamp-shared-lib; do
    printf '%s/%s\n' "$OWNER" "$repo"
  done
}

delete_artifact_candidate() {
  local repo="$1"
  local id="$2"
  local name="$3"
  local size="$4"
  local reason="$5"
  local created_at="$6"

  if [[ "$MODE" == "apply" ]]; then
    api_delete "/repos/$repo/actions/artifacts/$id"
    artifact_deleted=$((artifact_deleted + 1))
    artifact_bytes=$((artifact_bytes + size))
    log "deleted artifact repo=$repo id=$id name=$name bytes=$size created_at=$created_at reason=$reason"
  else
    artifact_deleted=$((artifact_deleted + 1))
    artifact_bytes=$((artifact_bytes + size))
    log "would delete artifact repo=$repo id=$id name=$name bytes=$size created_at=$created_at reason=$reason"
  fi
}

cleanup_artifacts() {
  local repo="$1"
  local now="$2"
  local artifact_cutoff=$((now - ARTIFACT_RETENTION_DAYS * 86400))
  local docker_image_cutoff=$((now - DOCKER_IMAGE_MAX_AGE_HOURS * 3600))
  local artifact_json

  artifact_json="$(gh api --paginate "/repos/$repo/actions/artifacts?per_page=100" \
    --jq '.artifacts[]? | @base64' 2>/dev/null || true)"

  if [[ -z "$artifact_json" ]]; then
    log "artifacts repo=$repo none-or-inaccessible"
    return
  fi

  while IFS= read -r encoded; do
    [[ -n "$encoded" ]] || continue
    local artifact
    artifact="$(printf '%s' "$encoded" | base64 --decode)"

    local id name size expired created_at created_epoch reason
    id="$(jq -r '.id' <<<"$artifact")"
    name="$(jq -r '.name' <<<"$artifact")"
    size="$(jq -r '.size_in_bytes // 0' <<<"$artifact")"
    expired="$(jq -r '.expired // false' <<<"$artifact")"
    created_at="$(jq -r '.created_at' <<<"$artifact")"
    created_epoch="$(iso_to_epoch "$created_at")"
    reason=""

    if [[ "$expired" == "true" ]]; then
      reason="expired"
    elif [[ "$name" == "docker-image" && "$created_epoch" -lt "$docker_image_cutoff" ]]; then
      reason="transfer-docker-image"
    elif [[ "$name" == *.dockerbuild && "$created_epoch" -lt "$artifact_cutoff" ]]; then
      reason="docker-build-record"
    elif [[ "$created_epoch" -lt "$artifact_cutoff" ]]; then
      reason="artifact-retention"
    fi

    if [[ -n "$reason" ]]; then
      delete_artifact_candidate "$repo" "$id" "$name" "$size" "$reason" "$created_at"
    fi
  done <<<"$artifact_json"
}

cache_group() {
  local key="$1"
  case "$key" in
    setup-java-*) echo "setup-java" ;;
    setup-python-*) echo "setup-python" ;;
    cache-trivy-* | trivy-binary-*) echo "trivy" ;;
    dependency-check-*) echo "dependency-check" ;;
    *) echo "" ;;
  esac
}

delete_cache_candidate() {
  local repo="$1"
  local id="$2"
  local key="$3"
  local size="$4"
  local reason="$5"

  if [[ "$MODE" == "apply" ]]; then
    api_delete "/repos/$repo/actions/caches/$id"
    cache_deleted=$((cache_deleted + 1))
    cache_bytes=$((cache_bytes + size))
    log "deleted cache repo=$repo id=$id key=$key bytes=$size reason=$reason"
  else
    cache_deleted=$((cache_deleted + 1))
    cache_bytes=$((cache_bytes + size))
    log "would delete cache repo=$repo id=$id key=$key bytes=$size reason=$reason"
  fi
}

cleanup_caches() {
  local repo="$1"
  local now="$2"
  local cache_cutoff=$((now - CACHE_RETENTION_DAYS * 86400))
  local cache_json

  cache_json="$(gh api --paginate "/repos/$repo/actions/caches?per_page=100" \
    --jq '.actions_caches[]? | @base64' 2>/dev/null || true)"

  if [[ -z "$cache_json" ]]; then
    log "caches repo=$repo none-or-inaccessible"
    return
  fi

  local rows_file protected_file deleted_file
  rows_file="$(mktemp)"
  protected_file="$(mktemp)"
  deleted_file="$(mktemp)"
  local total_bytes=0

  while IFS= read -r encoded; do
    [[ -n "$encoded" ]] || continue
    local cache id key size last_accessed created_at epoch group
    cache="$(printf '%s' "$encoded" | base64 --decode)"
    id="$(jq -r '.id' <<<"$cache")"
    key="$(jq -r '.key' <<<"$cache")"
    size="$(jq -r '.size_in_bytes // 0' <<<"$cache")"
    last_accessed="$(jq -r '.last_accessed_at // .created_at' <<<"$cache")"
    created_at="$(jq -r '.created_at' <<<"$cache")"
    epoch="$(iso_to_epoch "$last_accessed")"
    group="$(cache_group "$key")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$id" "$key" "$size" "$last_accessed" "$created_at" "$group" >>"$rows_file"
    total_bytes=$((total_bytes + size))
  done <<<"$cache_json"

  awk -F '\t' '
    $7 != "" {
      if (!($7 in max) || $1 > max[$7]) {
        max[$7] = $1
        id[$7] = $2
      }
    }
    END {
      for (group in id) {
        print id[group]
      }
    }
  ' "$rows_file" >"$protected_file"

  local remaining_bytes="$total_bytes"

  while IFS=$'\t' read -r epoch id key size _last_accessed _created_at _group; do
    if [[ "$epoch" -lt "$cache_cutoff" ]] && ! grep -Fxq "$id" "$protected_file"; then
      delete_cache_candidate "$repo" "$id" "$key" "$size" "cache-retention"
      printf '%s\n' "$id" >>"$deleted_file"
      remaining_bytes=$((remaining_bytes - size))
    fi
  done <"$rows_file"

  if [[ "$remaining_bytes" -gt "$CACHE_MAX_BYTES" ]]; then
    while IFS=$'\t' read -r _epoch id key size _last_accessed _created_at _group; do
      [[ "$remaining_bytes" -le "$CACHE_MAX_BYTES" ]] && break
      grep -Fxq "$id" "$protected_file" && continue
      grep -Fxq "$id" "$deleted_file" && continue
      delete_cache_candidate "$repo" "$id" "$key" "$size" "cache-cap"
      printf '%s\n' "$id" >>"$deleted_file"
      remaining_bytes=$((remaining_bytes - size))
    done < <(sort -n "$rows_file")
  fi

  log "cache summary repo=$repo current_bytes=$total_bytes target_bytes=$CACHE_MAX_BYTES projected_bytes=$remaining_bytes"
  rm -f "$rows_file" "$protected_file" "$deleted_file"
}

is_semver_like() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
}

is_dev_like() {
  [[ "$1" =~ ^(dev-|pr-|pull-|sha-|snapshot-|SNAPSHOT-|.*-SNAPSHOT$) ]]
}

cleanup_package_versions_for_type() {
  local package_type="$1"
  local now="$2"
  local cutoff=$((now - PACKAGE_RETENTION_DAYS * 86400))
  local base
  base="$(package_base_path)"

  local packages
  if ! packages="$(package_api --paginate "$base?package_type=$package_type" \
      --jq '.[]? | [.name, .visibility] | @tsv' 2>/dev/null)"; then
    log "packages type=$package_type skipped: token cannot list packages"
    return
  fi

  if [[ -z "$packages" ]]; then
    log "packages type=$package_type none"
    return
  fi

  while IFS=$'\t' read -r package_name _visibility; do
    [[ -n "$package_name" ]] || continue
    local encoded_name versions
    encoded_name="$(urlencode "$package_name")"
    versions="$(package_api --paginate "$base/$package_type/$encoded_name/versions?per_page=100" \
      --jq '.[]? | @base64' 2>/dev/null || true)"

    while IFS= read -r encoded; do
      [[ -n "$encoded" ]] || continue
      local version id name updated_at updated_epoch tag candidate reason
      version="$(printf '%s' "$encoded" | base64 --decode)"
      id="$(jq -r '.id' <<<"$version")"
      name="$(jq -r '.name // ""' <<<"$version")"
      updated_at="$(jq -r '.updated_at' <<<"$version")"
      updated_epoch="$(iso_to_epoch "$updated_at")"
      candidate="false"
      reason=""

      if [[ "$updated_epoch" -ge "$cutoff" ]]; then
        continue
      fi

      if [[ "$package_type" == "container" ]]; then
        local tags_text
        tags_text="$(jq -r '(.metadata.container.tags // [])[]' <<<"$version")"
        if [[ -z "$tags_text" ]]; then
          candidate="true"
          reason="untagged-container"
        else
          while IFS= read -r tag; do
            if is_semver_like "$tag"; then
              candidate="false"
              reason="kept-semver-tag:$tag"
              break
            fi
            if is_dev_like "$tag"; then
              candidate="true"
              reason="dev-container-tag:$tag"
            fi
          done <<<"$tags_text"
        fi
      elif is_semver_like "$name"; then
        candidate="false"
        reason="kept-semver-version:$name"
      elif is_dev_like "$name"; then
        candidate="true"
        reason="dev-package-version:$name"
      fi

      if [[ "$candidate" == "true" ]]; then
        if [[ "$PACKAGE_MODE" == "apply" ]]; then
          package_api -X DELETE "$base/$package_type/$encoded_name/versions/$id" >/dev/null
          package_deleted=$((package_deleted + 1))
          log "deleted package type=$package_type package=$package_name version=$name id=$id updated_at=$updated_at reason=$reason"
        else
          package_deleted=$((package_deleted + 1))
          log "would delete package type=$package_type package=$package_name version=$name id=$id updated_at=$updated_at reason=$reason"
        fi
      elif [[ -n "$reason" ]]; then
        log "kept package type=$package_type package=$package_name version=$name id=$id updated_at=$updated_at reason=$reason"
      fi
    done <<<"$versions"
  done <<<"$packages"
}

cleanup_packages() {
  local now="$1"
  local include
  include="$(normalize_bool "$INCLUDE_PACKAGES")"

  if [[ "$include" != "true" ]]; then
    log "packages skipped: include_packages=false"
    return
  fi

  if [[ -z "$PACKAGE_CLEANUP_TOKEN" ]]; then
    log "packages skipped: FSAMP_PACKAGE_CLEANUP_TOKEN/PACKAGE_CLEANUP_TOKEN is not set"
    return
  fi

  validate_mode "$PACKAGE_MODE" "PACKAGE_MODE"
  cleanup_package_versions_for_type "container" "$now"
  cleanup_package_versions_for_type "maven" "$now"
}

write_summary() {
  local summary="${GITHUB_STEP_SUMMARY:-}"
  [[ -n "$summary" ]] || return 0

  {
    echo "## Storage governance"
    echo ""
    echo "- mode: \`$MODE\`"
    echo "- artifacts selected/deleted: \`$artifact_deleted\` ($artifact_bytes bytes)"
    echo "- caches selected/deleted: \`$cache_deleted\` ($cache_bytes bytes)"
    echo "- package versions selected/deleted: \`$package_deleted\`"
  } >>"$summary"
}

main() {
  validate_mode "$MODE" "MODE"
  require_tool gh
  require_tool jq
  require_tool python3
  require_tool base64

  local now
  now="$(now_epoch)"

  log "storage governance mode=$MODE owner=$OWNER artifact_retention_days=$ARTIFACT_RETENTION_DAYS cache_retention_days=$CACHE_RETENTION_DAYS cache_max_bytes=$CACHE_MAX_BYTES"

  repos=()
  while IFS= read -r repo; do
    repos+=("$repo")
  done < <(discover_repos | awk 'NF' | sort -u)
  if [[ "${#repos[@]}" -eq 0 ]]; then
    die "No repositories selected"
  fi

  for repo in "${repos[@]}"; do
    log "::group::Repository $repo"
    cleanup_artifacts "$repo" "$now"
    cleanup_caches "$repo" "$now"
    log "::endgroup::"
  done

  cleanup_packages "$now"
  write_summary
}

main "$@"
