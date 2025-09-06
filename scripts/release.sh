#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh [vX.Y.Z] [options]

Options:
  --bump {patch|minor|major}  Считать следующий тег от последнего v* (если явный не указан)
  -m, --message MSG           Текст аннотации тега (release notes). По умолчанию — git log с прошлого тега
  -y, --yes                   Не спрашивать подтверждение
  -s, --skip-checks           Не проверять чистоту рабочей директории
  -h, --help                  Показать помощь
USAGE
}

die()  { echo "[release] ERROR: $*" >&2; exit 1; }
info() { echo "[release] $*"; }

TAG=""
MESSAGE=""
YES="false"
SKIP_CHECKS="false"
BUMP_PART=""

# --- разбор аргументов ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) YES="true" ;;
    -s|--skip-checks) SKIP_CHECKS="true" ;;
    --bump) shift; BUMP_PART="${1:-}";;
    -m|--message) shift; MESSAGE="${1:-}";;
    v[0-9]*)
      if [[ -z "$TAG" ]]; then
        TAG="$1"
      else
        die "Тег уже задан: $TAG"
      fi
      ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
  shift || true
done

# --- утилиты ---
semver_re='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

resolve_next() {
  local base="$1" part="$2"
  [[ "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "Некорректная текущая версия: $base"
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  case "$part" in
    patch) patch=$((patch+1));;
    minor) minor=$((minor+1)); patch=0;;
    major) major=$((major+1)); minor=0; patch=0;;
    *) die "Неизвестный bump: $part";;
  esac
  echo "${major}.${minor}.${patch}"
}

# --- git checks ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Не git-репозиторий"
git fetch -q --tags origin || true

# --- если bump ---
if [[ -z "$TAG" && -n "$BUMP_PART" ]]; then
  LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  BASE="${LAST_TAG#v}"; [[ -n "$BASE" ]] || BASE="0.0.0"
  NEXT="$(resolve_next "$BASE" "$BUMP_PART")"
  TAG="v$NEXT"
fi

[[ -n "$TAG" ]] || { usage; die "Нужен тег vX.Y.Z или --bump"; }
[[ "$TAG" =~ $semver_re ]] || die "Тег должен быть в формате vX.Y.Z (например v1.2.3)"

if [[ "$SKIP_CHECKS" != "true" ]]; then
  git diff --quiet && git diff --cached --quiet || die "Есть незакоммиченные изменения"
fi

# --- коллизии ---
if git rev-parse -q --verify "$TAG" >/dev/null 2>&1; then
  die "Тег '$TAG' уже есть локально"
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  die "Тег '$TAG' уже есть на origin"
fi

# --- релиз-ноты ---
if [[ -z "$MESSAGE" ]]; then
  LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$LAST_TAG" ]]; then
    HEADER="Release $TAG\n\nChanges since $LAST_TAG:"
    RANGE="$LAST_TAG..HEAD"
  else
    HEADER="Release $TAG\n\nChanges:"
    RANGE=""
  fi
  LOG="$(git log --no-merges --pretty=format:'- %h %s (%an)' ${RANGE} || true)"
  MESSAGE="$(printf "%b\n%b\n" "$HEADER" "${LOG:-No changes}")"
fi

# --- подтверждение ---
info "Готовим релиз: $TAG"
echo "---- Release notes ----"
echo "$MESSAGE"
echo "-----------------------"
if [[ "$YES" != "true" ]]; then
  read -r -p "Создать и запушить тег '$TAG'? [y/N] " ans
  [[ ${ans:-N} =~ ^[Yy]$ ]] || exit 1
fi

# --- создаём и пушим ---
git tag -a "$TAG" -m "$MESSAGE"
git push origin "$TAG"

info "Тег $TAG создан и отправлен."
