#!/usr/bin/env bash
set -euo pipefail

IMAGES_FILE="${IMAGES_FILE:?IMAGES_FILE is required}"
SELECTION="${SELECTION:-}"
EVENT_NAME="${EVENT_NAME:-}"
BASE="${BASE:-}"
HEAD="${HEAD:-HEAD}"

select_dispatch() {
  local selection="$1" file="$2"
  local trimmed
  trimmed=$(echo "$selection" | xargs || true)
  if [ -z "$trimmed" ] || [ "$trimmed" = "all" ]; then
    jq -c '.' "$file"
    return
  fi

  local valid_names
  valid_names=$(jq -r '[.[].name] | unique | join(", ")' "$file")
  local result="[]"
  local token name variant match

  IFS=',' read -ra tokens <<< "$trimmed"
  for raw in "${tokens[@]}"; do
    token=$(echo "$raw" | xargs)
    [ -z "$token" ] && continue
    if [ "$token" = "all" ]; then
      jq -c '.' "$file"
      return
    fi
    if [[ "$token" == *:* ]]; then
      name="${token%%:*}"
      variant="${token#*:}"
      match=$(jq -c --arg n "$name" --arg v "$variant" '[.[] | select(.name == $n and .variant == $v)]' "$file")
    else
      match=$(jq -c --arg n "$token" '[.[] | select(.name == $n)]' "$file")
    fi
    if [ "$(jq 'length' <<< "$match")" -eq 0 ]; then
      echo "unknown selection '$token', valid names: $valid_names, all" >&2
      exit 1
    fi
    result=$(jq -c -s '.[0] + .[1] | unique_by(.name + (.variant // ""))' <<< "$result"$'\n'"$match")
  done

  echo "$result"
}

select_diff() {
  local base="$1" head="$2" file="$3"
  if [ -z "$base" ] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    jq -c '.' "$file"
    return
  fi

  local changed files
  changed=$(git diff --name-only "$base" "$head")
  files=$(echo "$changed" | grep -v '\.md$' || true)
  files=$(echo "$files" | sed '/^$/d')

  if [ -z "$files" ]; then
    echo "[]"
    return
  fi

  local contexts outside f c matched
  contexts=$(jq -r '[.[].context] | unique | .[]' "$file")
  outside=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    matched=0
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if [[ "$f" == "$c"/* ]]; then
        matched=1
        break
      fi
    done <<< "$contexts"
    if [ "$matched" -eq 0 ]; then
      outside=1
      break
    fi
  done <<< "$files"

  if [ "$outside" -eq 1 ]; then
    jq -c '.' "$file"
    return
  fi

  jq -c --arg files "$files" '
    ($files | split("\n") | map(select(length > 0))) as $fs
    | [.[] | select(.context as $c | $fs | any(startswith($c + "/")))]
  ' "$file"
}

case "$EVENT_NAME" in
  workflow_dispatch)
    include=$(select_dispatch "$SELECTION" "$IMAGES_FILE")
    ;;
  schedule)
    include=$(jq -c '.' "$IMAGES_FILE")
    ;;
  *)
    include=$(select_diff "$BASE" "$HEAD" "$IMAGES_FILE")
    ;;
esac

count=$(jq 'length' <<< "$include")
matrix=$(jq -c -n --argjson include "$include" '{include: $include}')
if [ "$count" -eq 0 ]; then
  empty=true
else
  empty=false
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
  echo "empty=$empty" >> "$GITHUB_OUTPUT"
else
  echo "matrix=$matrix"
  echo "empty=$empty"
fi
