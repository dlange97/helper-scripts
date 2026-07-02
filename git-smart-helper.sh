#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="${1:-$PROJECT_ROOT_DEFAULT}"

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "[ERROR] Project root does not exist: $PROJECT_ROOT"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[ERROR] git is required but not found."
  exit 1
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "[ERROR] This script requires an interactive terminal (TTY)."
  echo "[HINT] Run it without redirection: ./git-smart-helper.sh"
  exit 1
fi

CURRENT_REPO=""
ALL_REPOS=()

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

collect_repos() {
  local root="$1"
  local result=()

  while IFS= read -r git_dir; do
    [[ -z "$git_dir" ]] && continue
    result+=("${git_dir%/.git}")
  done < <(
    find "$root" \
      \( -type d \( -name node_modules -o -name vendor -o -name .venv -o -name coverage -o -name dist -o -name build \) -prune \) -o \
      \( -type d -name .git -print \) | sort
  )

  if (( ${#result[@]} == 0 )); then
    echo "[ERROR] No git repositories found under: $root"
    exit 1
  fi

  printf '%s\n' "${result[@]}"
}

contains_ci() {
  local haystack="$1"
  local needle="$2"
  printf '%s' "$haystack" | tr '[:upper:]' '[:lower:]' | grep -Fq "$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')"
}

choose_from_matches() {
  local title="$1"
  shift
  local items=("$@")

  echo ""
  echo "$title"
  local i=1
  for item in "${items[@]}"; do
    printf '  [%d] %s\n' "$i" "$item"
    i=$((i + 1))
  done

  while true; do
    read -r -p "Select a number [1-${#items[@]}] or q to cancel: " pick
    pick="$(trim "$pick")"

    if [[ "$pick" == "q" || "$pick" == "Q" ]]; then
      return 1
    fi

    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#items[@]} )); then
      printf '%s' "${items[pick-1]}"
      return 0
    fi

    echo "[WARN] Invalid selection."
  done
}

select_repo() {
  local repos=()
  while IFS= read -r repo; do
    repos+=("$repo")
  done < <(collect_repos "$PROJECT_ROOT")

  ALL_REPOS=("${repos[@]}")

  local rel_repos=()
  local repo
  for repo in "${repos[@]}"; do
    rel_repos+=("${repo#$PROJECT_ROOT/}")
  done

  echo ""
  echo "[INFO] Available repositories under: $PROJECT_ROOT"
  printf '  [%d] %s\n' 1 "[ALL] all repositories"
  local idx=2
  for repo in "${rel_repos[@]}"; do
    printf '  [%d] %s\n' "$idx" "$repo"
    idx=$((idx + 1))
  done

  while true; do
    echo ""
    read -r -p "Type part of a folder/repo name (Enter = show full list): " query
    query="$(trim "$query")"

    if [[ -z "$query" ]]; then
      local menu_items=("[ALL] all repositories")
      menu_items+=("${rel_repos[@]}")

      local selected
      if selected="$(choose_from_matches "Choose repository:" "${menu_items[@]}")"; then
        if [[ "$selected" == "[ALL] all repositories" ]]; then
          CURRENT_REPO="__ALL__"
          echo "[INFO] Selected: all repositories"
        else
          CURRENT_REPO="$PROJECT_ROOT/$selected"
        fi
        break
      else
        echo "[INFO] Selection canceled."
        continue
      fi
    fi

    local matches=()
    if contains_ci "all repositories" "$query" || contains_ci "all" "$query"; then
      matches+=("[ALL] all repositories")
    fi

    local rel
    for rel in "${rel_repos[@]}"; do
      if contains_ci "$rel" "$query"; then
        matches+=("$rel")
      fi
    done

    if (( ${#matches[@]} == 0 )); then
      echo "[WARN] No matches found for: $query"
      continue
    fi

    if (( ${#matches[@]} == 1 )); then
      if [[ "${matches[0]}" == "[ALL] all repositories" ]]; then
        CURRENT_REPO="__ALL__"
        echo "[INFO] Selected: all repositories"
      else
        CURRENT_REPO="$PROJECT_ROOT/${matches[0]}"
        echo "[INFO] Selected: ${matches[0]}"
      fi
      break
    fi

    echo "[INFO] Found ${#matches[@]} matches (suggestions):"
    local j=1
    for rel in "${matches[@]}"; do
      printf '  [%d] %s\n' "$j" "$rel"
      j=$((j + 1))
    done

    local selected
    if selected="$(choose_from_matches "Choose repository from suggestions:" "${matches[@]}")"; then
      if [[ "$selected" == "[ALL] all repositories" ]]; then
        CURRENT_REPO="__ALL__"
      else
        CURRENT_REPO="$PROJECT_ROOT/$selected"
      fi
      break
    fi
  done
}

list_branches() {
  git -C "$CURRENT_REPO" for-each-ref refs/heads --format='%(refname:short)' | sort
}

pick_branch() {
  local branches=()
  while IFS= read -r b; do
    [[ -n "$b" ]] && branches+=("$b")
  done < <(list_branches)

  if (( ${#branches[@]} == 0 )); then
    echo "[WARN] No local branches found."
    return 1
  fi

  while true; do
    echo ""
    read -r -p "Type branch name (or fragment, Enter = show list): " query
    query="$(trim "$query")"

    if [[ -z "$query" ]]; then
      choose_from_matches "Choose branch:" "${branches[@]}"
      return $?
    fi

    local matches=()
    local br
    for br in "${branches[@]}"; do
      if contains_ci "$br" "$query"; then
        matches+=("$br")
      fi
    done

    if (( ${#matches[@]} == 0 )); then
      echo "[WARN] No matching branches found."
      continue
    fi

    if (( ${#matches[@]} == 1 )); then
      printf '%s' "${matches[0]}"
      return 0
    fi

    echo "[INFO] Branch suggestions (${#matches[@]}):"
    local i=1
    for br in "${matches[@]}"; do
      printf '  [%d] %s\n' "$i" "$br"
      i=$((i + 1))
    done

    choose_from_matches "Choose branch from suggestions:" "${matches[@]}"
    return $?
  done
}

show_repo_header() {
  if [[ "$CURRENT_REPO" == "__ALL__" ]]; then
    echo ""
    echo "========================================================"
    echo "Repo mode: ALL repositories (${#ALL_REPOS[@]})"
    echo "Action:    checkout main/master only"
    echo "========================================================"
    return
  fi

  local rel_repo="${CURRENT_REPO#$PROJECT_ROOT/}"
  local current_branch
  current_branch="$(git -C "$CURRENT_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"

  echo ""
  echo "========================================================"
  echo "Repo:    $rel_repo"
  echo "Branch:  $current_branch"
  echo "========================================================"
}

action_checkout_branch() {
  local branch
  if ! branch="$(pick_branch)"; then
    echo "[INFO] Checkout canceled."
    return
  fi

  echo "[INFO] Checkout -> $branch"
  git -C "$CURRENT_REPO" checkout "$branch"
}

action_create_branch() {
  read -r -p "Enter new branch name: " new_branch
  new_branch="$(trim "$new_branch")"

  if [[ -z "$new_branch" ]]; then
    echo "[WARN] Branch name cannot be empty."
    return
  fi

  if git -C "$CURRENT_REPO" show-ref --verify --quiet "refs/heads/$new_branch"; then
    echo "[WARN] Branch already exists: $new_branch"
    read -r -p "Switch to existing branch? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      git -C "$CURRENT_REPO" checkout "$new_branch"
    fi
    return
  fi

  git -C "$CURRENT_REPO" checkout -b "$new_branch"
}

action_pull() {
  git -C "$CURRENT_REPO" pull
}

action_fetch() {
  git -C "$CURRENT_REPO" fetch --all --prune
}

action_push() {
  local branch
  branch="$(git -C "$CURRENT_REPO" rev-parse --abbrev-ref HEAD)"

  if git -C "$CURRENT_REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git -C "$CURRENT_REPO" push
  else
    git -C "$CURRENT_REPO" push -u origin "$branch"
  fi
}

action_status() {
  git -C "$CURRENT_REPO" status -sb
}

action_create_commit() {
  read -r -p "Enter commit message: " msg
  msg="$(trim "$msg")"

  if [[ -z "$msg" ]]; then
    echo "[WARN] Commit message cannot be empty."
    return
  fi

  git -C "$CURRENT_REPO" add -A
  if git -C "$CURRENT_REPO" diff --cached --quiet; then
    echo "[INFO] No changes to commit."
    return
  fi

  git -C "$CURRENT_REPO" commit -m "$msg"
}

action_checkout_main_like() {
  if git -C "$CURRENT_REPO" show-ref --verify --quiet refs/heads/main; then
    git -C "$CURRENT_REPO" checkout main
    return
  fi

  if git -C "$CURRENT_REPO" show-ref --verify --quiet refs/heads/master; then
    git -C "$CURRENT_REPO" checkout master
    return
  fi

  echo "[WARN] Neither main nor master branch was found."
}

action_checkout_main_like_all() {
  if (( ${#ALL_REPOS[@]} == 0 )); then
    echo "[WARN] No repositories available in all-repositories mode."
    return
  fi

  local repo
  for repo in "${ALL_REPOS[@]}"; do
    local rel_repo="${repo#$PROJECT_ROOT/}"

    if git -C "$repo" show-ref --verify --quiet refs/heads/main; then
      echo "[INFO] [$rel_repo] checkout main"
      git -C "$repo" checkout main
      continue
    fi

    if git -C "$repo" show-ref --verify --quiet refs/heads/master; then
      echo "[INFO] [$rel_repo] checkout master"
      git -C "$repo" checkout master
      continue
    fi

    echo "[WARN] [$rel_repo] Neither main nor master branch was found."
  done
}

action_pull_all() {
  if (( ${#ALL_REPOS[@]} == 0 )); then
    echo "[WARN] No repositories available in all-repositories mode."
    return
  fi

  local repo
  for repo in "${ALL_REPOS[@]}"; do
    local rel_repo="${repo#$PROJECT_ROOT/}"
    echo "[INFO] [$rel_repo] pull"

    if ! git -C "$repo" pull; then
      echo "[WARN] [$rel_repo] pull failed, continuing with next repository."
    fi
  done
}

main_menu() {
  while true; do
    show_repo_header
    if [[ "$CURRENT_REPO" == "__ALL__" ]]; then
      echo "What do you want to do in Git?"
      echo "  [1] Checkout main/master in ALL repositories"
      echo "  [2] Pull in ALL repositories"
      echo "  [9] Change repo/folder"
      echo "  [0] Exit"
    else
      echo "What do you want to do in Git?"
      echo "  [1] Status"
      echo "  [2] Checkout branch"
      echo "  [3] Create branch (checkout -b)"
      echo "  [4] Pull"
      echo "  [5] Fetch --all --prune"
      echo "  [6] Push"
      echo "  [7] Add + Commit"
      echo "  [8] Checkout main/master"
      echo "  [9] Change repo/folder"
      echo "  [0] Exit"
    fi

    read -r -p "Selection: " choice
    choice="$(trim "$choice")"

    if [[ "$CURRENT_REPO" == "__ALL__" ]]; then
      case "$choice" in
        1) action_checkout_main_like_all ;;
        2) action_pull_all ;;
        9) select_repo ;;
        0) echo "[DONE] Goodbye."; exit 0 ;;
        *) echo "[WARN] Unknown option." ;;
      esac
    else
      case "$choice" in
        1) action_status ;;
        2) action_checkout_branch ;;
        3) action_create_branch ;;
        4) action_pull ;;
        5) action_fetch ;;
        6) action_push ;;
        7) action_create_commit ;;
        8) action_checkout_main_like ;;
        9) select_repo ;;
        0) echo "[DONE] Goodbye."; exit 0 ;;
        *) echo "[WARN] Unknown option." ;;
      esac
    fi
  done
}

select_repo
main_menu
