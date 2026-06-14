#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_ROOT="${1:-$APP_ROOT_DEFAULT}"

if [[ ! -d "$APP_ROOT" ]]; then
  echo "[ERROR] App root not found: $APP_ROOT"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[ERROR] git is required."
  exit 1
fi

build_commit_message() {
  local repo_name="$1"
  local change_count="$2"
  local files_blob="$3"

  if (( change_count > 20 )); then
    echo "chore: ${repo_name} update"
    return
  fi

  local area_count
  area_count="$(printf '%s\n' "$files_blob" | awk -F/ 'NF>0{print $1}' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"

  if [[ -z "$area_count" || "$area_count" -eq 0 || "$area_count" -gt 4 ]]; then
    echo "chore: ${repo_name} update"
    return
  fi

  local areas
  areas="$(printf '%s\n' "$files_blob" | awk -F/ 'NF>0{print $1}' | sed '/^$/d' | sort -u | paste -sd '+' -)"

  if [[ -n "$areas" ]]; then
    echo "chore: ${repo_name} update (${areas})"
  else
    echo "chore: ${repo_name} update"
  fi
}

git_dirs=()
while IFS= read -r line; do
  git_dirs+=("$line")
done < <(find "$APP_ROOT" -type d -name .git -prune | sort)

if (( ${#git_dirs[@]} == 0 )); then
  echo "[INFO] No git repositories found under: $APP_ROOT"
  exit 0
fi

repos=()
for git_dir in "${git_dirs[@]}"; do
  repos+=("${git_dir%/.git}")
done

changed_repos=()
changed_counts=()
changed_files=()
total_changed_files=0

for repo in "${repos[@]}"; do
  if ! status_output="$(git -C "$repo" status --porcelain 2>/dev/null)"; then
    echo "[WARN] Skipping invalid git repo: $repo"
    continue
  fi

  if [[ -z "$status_output" ]]; then
    continue
  fi

  files_blob="$(printf '%s\n' "$status_output" | sed -E 's/^.. //')"
  file_count="$(printf '%s\n' "$files_blob" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$file_count" -eq 0 ]]; then
    continue
  fi

  changed_repos+=("$repo")
  changed_counts+=("$file_count")
  changed_files+=("$files_blob")

  total_changed_files=$((total_changed_files + file_count))
done

if (( ${#changed_repos[@]} == 0 )); then
  echo "[INFO] No changes detected in repositories under: $APP_ROOT"
  exit 0
fi

echo "[INFO] Found changes in ${#changed_repos[@]} repositories."
echo "[INFO] Total changed paths: $total_changed_files"

if (( total_changed_files > 50 )); then
  read -r -p "[PROMPT] More than 50 changed paths detected. Push ALL changes? [y/N]: " confirm_all
  if [[ ! "$confirm_all" =~ ^[Yy]$ ]]; then
    echo "[INFO] Aborted by user."
    exit 0
  fi
fi

for i in "${!changed_repos[@]}"; do
  repo="${changed_repos[$i]}"
  count="${changed_counts[$i]}"
  files_blob="${changed_files[$i]}"
  repo_name="$(basename "$repo")"

  message="$(build_commit_message "$repo_name" "$count" "$files_blob")"

  echo ""
  echo "[INFO] Processing repo: $repo"
  echo "[INFO] Changed paths: $count"
  echo "[INFO] Commit message: $message"

  git -C "$repo" add -A

  if git -C "$repo" diff --cached --quiet; then
    echo "[INFO] Nothing staged after add, skipping."
    continue
  fi

  git -C "$repo" commit -m "$message"

  if git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git -C "$repo" push
  else
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
    git -C "$repo" push -u origin "$branch"
  fi

done

echo ""
echo "[DONE] Commit + push completed for all changed repositories under: $APP_ROOT"
