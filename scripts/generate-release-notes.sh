#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "usage: $0 <current-tag> [output-file]" >&2
  exit 1
fi

CURRENT_TAG="$1"
OUTPUT_FILE="${2:-}"
REPO_URL="${REPO_URL:-https://github.com/vincentkoc/autosecure}"
PREV_TAG="$(git tag --sort=-version:refname | grep -v "^${CURRENT_TAG}$" | head -n 1 || true)"

if [ -n "$PREV_TAG" ]; then
  RANGE="${PREV_TAG}..${CURRENT_TAG}"
else
  RANGE="${CURRENT_TAG}"
fi

COMMITS="$(git log --pretty=format:'%h%x09%s' "${RANGE}")"
COMMON_PREFIX_RE='^[[:space:]]*(feat|feature|enhancement|fix|bug|perf|refactor|docs|build|ci|test|tests|chore|dependencies|dep|deps)(\([^)]+\))?:'

emit() {
  local line="$1"
  if [ -n "$OUTPUT_FILE" ]; then
    printf '%s\n' "$line" >> "$OUTPUT_FILE"
  else
    printf '%s\n' "$line"
  fi
}

subject_matches() {
  local subject="$1"
  local pattern="$2"
  printf '%s\n' "$subject" | grep -Eq "$pattern"
}

if [ -n "$OUTPUT_FILE" ]; then
  : > "$OUTPUT_FILE"
fi

emit "## What's Changed"
emit ""

add_section() {
  local title="$1"
  local pattern="$2"
  local count=0

  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if subject_matches "$subject" "$pattern"; then
      if [ "$count" -eq 0 ]; then
        emit "### ${title}"
      fi
      emit "- ${subject} (\`${sha}\`)"
      count=$((count + 1))
    fi
  done <<< "$COMMITS"

  if [ "$count" -gt 0 ]; then
    emit ""
  fi
}

add_section "🚀 Features" '^[[:space:]]*(feat|feature|enhancement)(\([^)]+\))?:'
add_section "🐛 Fixes" '^[[:space:]]*(fix|bug)(\([^)]+\))?:'
add_section "🧰 Maintenance" '^[[:space:]]*(perf|refactor|docs|build|ci|test|tests|chore|dependencies|dep|deps)(\([^)]+\))?:'

other_count=0
while IFS=$'\t' read -r sha subject; do
  [ -n "$sha" ] || continue
  if ! subject_matches "$subject" "$COMMON_PREFIX_RE"; then
    if [ "$other_count" -eq 0 ]; then
      emit "### Other Changes"
    fi
    emit "- ${subject} (\`${sha}\`)"
    other_count=$((other_count + 1))
  fi
done <<< "$COMMITS"

if [ "$other_count" -gt 0 ]; then
  emit ""
fi

if [ -n "$PREV_TAG" ]; then
  emit "Full Changelog: ${REPO_URL}/compare/${PREV_TAG}...${CURRENT_TAG}"
else
  emit "Full Changelog: ${REPO_URL}/tree/${CURRENT_TAG}"
fi
