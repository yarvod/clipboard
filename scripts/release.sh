#!/usr/bin/env bash
set -euo pipefail

# ClipboardCommander release helper
# Creates an annotated tag (vX.Y.Z), pushes it to origin, triggering GitHub Actions release.

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [<tag>] [options]

Arguments:
  <tag>                 Version tag to release (e.g., v1.2.3). Optional with --bump/--set-version

Options:
  -m, --message <msg>   Tag message (release notes). If not set, generated from git log.
  -y, --yes             Non-interactive; do not ask for confirmation.
  -s, --skip-checks     Skip clean working tree and branch checks.
  -p, --pre-commit      Run `pre-commit run --all-files` before tagging.
  -b, --build-local     Run ./build.sh locally before tagging (sanity check).
  --bump <part>         Auto bump version: patch | minor | major. Computes next tag from last tag or VERSION.
  --set-version <ver>   Set version explicitly (e.g., 1.2.3) and derive tag v<ver>.
  --sign / --no-sign    Create GPG-signed tag if possible (default --sign; falls back to annotated).
  -n, --dry-run         Show what would happen without creating/pushing a tag.
  -h, --help            Show this help.

Examples:
  scripts/release.sh v1.0.0 -p -b
  scripts/release.sh --bump patch -p
  scripts/release.sh --set-version 1.1.0 -m "Minor fixes" -y
USAGE
}

die() { echo "[release] ERROR: $*" >&2; exit 1; }
info() { echo "[release] $*"; }

TAG=""
MESSAGE=""
YES="false"
SKIP_CHECKS="false"
RUN_PRE_COMMIT="false"
BUILD_LOCAL="false"
DRY_RUN="false"
WANT_SIGN="true"
BUMP_PART=""
SET_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -m|--message) shift; MESSAGE=${1:-""} ;;
    -y|--yes) YES="true" ;;
    -s|--skip-checks) SKIP_CHECKS="true" ;;
    -p|--pre-commit) RUN_PRE_COMMIT="true" ;;
    -b|--build-local) BUILD_LOCAL="true" ;;
    -n|--dry-run) DRY_RUN="true" ;;
    --bump) shift; BUMP_PART=${1:-""} ;;
    --set-version) shift; SET_VERSION=${1:-""} ;;
    --sign) WANT_SIGN="true" ;;
    --no-sign) WANT_SIGN="false" ;;
    v*) if [[ -z "$TAG" ]]; then TAG="$1"; else die "Tag already set to '$TAG'"; fi ;;
    *) if [[ -z "$TAG" ]]; then TAG="$1"; else die "Unknown arg: $1"; fi ;;
  esac
  shift || true
done

# Resolve desired tag if not provided
resolve_next_version() {
  local part="$1"; local cur="$2"
  if [[ ! "$cur" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    die "Invalid current version: $cur"
  fi
  local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
  case "$part" in
    patch) patch=$((patch+1));;
    minor) minor=$((minor+1)); patch=0;;
    major) major=$((major+1)); minor=0; patch=0;;
    *) die "Unknown bump part: $part";;
  esac
  echo "$major.$minor.$patch"
}

if [[ -z "$TAG" ]]; then
  if [[ -n "$SET_VERSION" ]]; then
    [[ "$SET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--set-version must be x.y.z"
    TAG="v$SET_VERSION"
  elif [[ -n "$BUMP_PART" ]]; then
    CURV="$( (git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' ) || true)"
    if [[ -z "$CURV" ]]; then
      CURV="$(cat VERSION 2>/dev/null || echo '0.0.0')"
    fi
    NEXTV="$(resolve_next_version "$BUMP_PART" "$CURV")"
    TAG="v$NEXTV"
  fi
fi

[[ -n "$TAG" ]] || { usage; die "Tag is required (or use --bump/--set-version)"; }

# Basic tag validation
if ! [[ "$TAG" =~ ^v[0-9]+(\.[0-9]+)*([A-Za-z0-9._-]+)?$ ]]; then
  die "Tag must start with 'v' and contain digits, e.g. v1.2.3"
fi

# Ensure git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository"

CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD || echo "detached")
if [[ "$SKIP_CHECKS" != "true" ]]; then
  # Clean tree check
  git diff --quiet || die "Uncommitted changes present; commit or stash them"
  git diff --cached --quiet || die "Staged but uncommitted changes present; commit or unstage"
  # Branch hint
  if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
    info "Warning: you are on branch '$CURRENT_BRANCH' (not main/master)."
    if [[ "$YES" != "true" ]]; then
      read -r -p "Continue? [y/N] " ans; [[ ${ans:-N} =~ ^[Yy]$ ]] || exit 1
    fi
  fi
fi

# Optional pre-commit
if [[ "$RUN_PRE_COMMIT" == "true" ]]; then
  if command -v pre-commit >/dev/null 2>&1; then
    info "Running pre-commit hooks..."
    pre-commit run --all-files
  else
    info "pre-commit not found; skipping"
  fi
fi

# Generate release notes if not provided
if [[ -z "$MESSAGE" ]]; then
  LAST_TAG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")
  RANGE=""
  if [[ -n "$LAST_TAG" ]]; then
    RANGE="$LAST_TAG..HEAD"
    HEADER="Release $TAG\n\nChanges since $LAST_TAG:"
  else
    HEADER="Release $TAG\n\nChanges:"
  fi
  LOG=$(git log --no-merges --pretty=format:"- %h %s (%an)" ${RANGE} || true)
  MESSAGE=$(printf "%b\n%b\n" "$HEADER" "${LOG:-No changes collected}" )
fi

# Show summary and confirm
info "Preparing to create tag '$TAG' on '$CURRENT_BRANCH'"
echo "================ Release notes ================"
echo "$MESSAGE"
echo "=============================================="
if [[ "$YES" != "true" ]]; then
  read -r -p "Create and push tag '$TAG'? [y/N] " ans; [[ ${ans:-N} =~ ^[Yy]$ ]] || exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  info "Dry run enabled; not creating tag."
  exit 0
fi

# Check tag collisions
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "Tag '$TAG' already exists locally"
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  die "Tag '$TAG' already exists on origin"
fi

# If bump or set-version, update version files and changelog, commit
DESIRED_VER="$(echo "$TAG" | sed 's/^v//')"
if [[ -n "$BUMP_PART" || -n "$SET_VERSION" ]]; then
  info "Updating VERSION and __init__.__version__ to $DESIRED_VER"
  echo "$DESIRED_VER" > VERSION
  if [[ -f clipboard_commander/__init__.py ]]; then
    perl -pi -e 's/^(__version__\s*=\s*").*(")/\1'$DESIRED_VER'\2/' clipboard_commander/__init__.py || true
  fi
  # Rebuild short log for changelog
  LAST_TAG_FOR_LOG=$(git describe --tags --abbrev=0 --match "v*" 2>/dev/null || echo "")
  RANGE_FOR_LOG=""
  if [[ -n "$LAST_TAG_FOR_LOG" ]]; then RANGE_FOR_LOG="$LAST_TAG_FOR_LOG..HEAD"; fi
  LOG_SHORT=$(git log --no-merges --pretty=format:"- %h %s (%an)" ${RANGE_FOR_LOG} || true)
  DATE=$(date +%F)
  SECTION=$(printf "## %s — %s\n\n%s\n\n" "$TAG" "$DATE" "${LOG_SHORT:-No changes collected}")
  if [[ -f CHANGELOG.md ]]; then
    awk -v sec="$SECTION" 'NR==1{print; print ""; print sec; next} {print}' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md
  else
    printf "# Changelog\n\n%s\n" "$SECTION" > CHANGELOG.md
  fi
  git add VERSION clipboard_commander/__init__.py CHANGELOG.md 2>/dev/null || true
  git commit -m "chore(release): $TAG" || true
fi

# Optional local build sanity check
if [[ "$BUILD_LOCAL" == "true" ]]; then
  if [[ -x ./build.sh ]]; then
    info "Running local build.sh before tagging..."
    ./build.sh
  else
    info "build.sh not executable or missing; skipping local build"
  fi
fi

# Create tag (signed if possible) and push
info "Creating tag $TAG"
if [[ "$WANT_SIGN" == "true" ]]; then
  SIGN_FORMAT=$(git config --get gpg.format || true)
  if [[ "$SIGN_FORMAT" == "ssh" ]]; then
    # SSH signing: no gpg required; relies on ssh-agent and user.signingkey (.pub)
    git tag -s "$TAG" -m "$MESSAGE" || { info "SSH signing failed, falling back to annotated tag"; git tag -a "$TAG" -m "$MESSAGE"; }
  else
    # GPG/OpenPGP signing
    if git config user.signingkey >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
      git tag -s "$TAG" -m "$MESSAGE" || { info "GPG signing failed, falling back to annotated tag"; git tag -a "$TAG" -m "$MESSAGE"; }
    else
      info "Signing not configured (gpg or key missing); creating annotated tag"
      git tag -a "$TAG" -m "$MESSAGE"
    fi
  fi
else
  git tag -a "$TAG" -m "$MESSAGE"
fi
info "Pushing tag to origin"
git push origin "$TAG"

# Derive GitHub repo slug to print helpful URLs
ORIGIN_URL=$(git config --get remote.origin.url || echo "")
REPO_SLUG=""
if [[ "$ORIGIN_URL" =~ github.com[:/](.+)\.git$ ]]; then
  REPO_SLUG="${BASH_REMATCH[1]}"
fi

info "Done. GitHub Actions will build and attach macOS artifacts."
if [[ -n "$REPO_SLUG" ]]; then
  echo "- Actions: https://github.com/$REPO_SLUG/actions"
  echo "- Release: https://github.com/$REPO_SLUG/releases/tag/$TAG"
fi
