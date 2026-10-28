#!/usr/bin/env bash
# Install or bump the emergy.cloud CI of a repository: the four contract stubs
# (.github/workflows/{build,deploy,update-infrastructure,delete-infrastructure}.yml)
# and, in vendor mode, the four reusable logic files they call. Offline: every
# file comes from this repository's git objects (git show <rev>:<path>), so the
# output is reproducible from a sha. It writes only the files it lists.
#
#   scripts/install.sh --mode ref    --ref v10     --target ../my-repo     # follows the moving major
#   scripts/install.sh --mode ref    --ref v10.0.0 --target ../my-repo     # pinned
#   scripts/install.sh --mode vendor --ref v10.0.0 --target ../client-repo # orgs that must not reference
#                                                                          # emergy-cloud/workflows (HQ D4/D9)
# Re-run the same command with another --ref to bump. See README.md
# ("Install and bump") and docs/adoption.md.
set -euo pipefail

FILES="build deploy update-infrastructure delete-infrastructure"
CONTRACT_ENVS="dev staging prod"
THIS_REPO="emergy-cloud/workflows"

usage() {
  cat <<'EOF'
Usage: scripts/install.sh --mode ref|vendor --ref REF --target DIR [options]

  --mode ref     write the 4 stubs calling emergy-cloud/workflows/.github/workflows/<file>@REF;
                 REF is vN (follow the moving major), vN.N.N or a full commit sha (pinned)
  --mode vendor  write the 4 stubs calling ./.github/workflows/vendored-<file>.yml plus those
                 4 vendored logic files, copied from this repository at REF (a tag, a branch
                 or a sha; the resolved sha is stamped in each header)
  --ref REF      see --mode (required)
  --target DIR   root of the repository to write into (required)
  --envs LIST    ENVS fallback written into the stubs, a subset of dev,staging,prod
                 (default: the fallback of the target's current build.yml, else dev,staging,prod)
  --stack NAME   stub set under stubs/ (default: astro)
  --from REV     ref mode only: read the stub templates from REV of this repository
                 (default: REF when it exists in this clone, else HEAD)
  -h, --help     this help

Writes only .github/workflows/{build,deploy,update-infrastructure,delete-infrastructure}.yml
and, in vendor mode, .github/workflows/vendored-<same names>.yml. Nothing else is touched.
EOF
}
die() { echo "install.sh: $*" >&2; exit 1; }
usage_die() { echo "install.sh: $*" >&2; echo "Run scripts/install.sh --help for usage." >&2; exit 2; }

MODE="" REF="" TARGET="" ENVS_ARG="" STACK="astro" FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --mode|--ref|--target|--envs|--stack|--from)
      [ $# -ge 2 ] || usage_die "$1 needs a value"
      case "$1" in
        --mode) MODE="$2" ;; --ref) REF="$2" ;; --target) TARGET="$2" ;;
        --envs) ENVS_ARG="$2" ;; --stack) STACK="$2" ;; --from) FROM="$2" ;;
      esac
      shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    --ref=*) REF="${1#*=}"; shift ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --envs=*) ENVS_ARG="${1#*=}"; shift ;;
    --stack=*) STACK="${1#*=}"; shift ;;
    --from=*) FROM="${1#*=}"; shift ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done
case "$MODE" in ref|vendor) ;; "") usage_die "--mode is required (ref or vendor)" ;; *) usage_die "--mode must be ref or vendor, not '$MODE'" ;; esac
[ -n "$REF" ] || usage_die "--ref is required"
[ -n "$TARGET" ] || usage_die "--target is required"
[[ "$STACK" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage_die "--stack must be a plain name, not '$STACK'"

WF_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
git -C "$WF_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$WF_ROOT is not a git checkout of $THIS_REPO"
[ -d "$TARGET" ] || die "target '$TARGET' is not a directory"
TARGET_ABS="$(cd "$TARGET" && pwd -P)"
# Writing stubs over this repository's own logic files is exactly how commit
# d372cff broke it: refuse this checkout and any other copy of it.
if [ "$TARGET_ABS" = "$WF_ROOT" ] || { [ -f "$TARGET_ABS/scripts/install.sh" ] && [ -d "$TARGET_ABS/stubs" ]; }; then
  die "refusing to write into a checkout of $THIS_REPO itself ($TARGET_ABS): its .github/workflows holds the logic, not stubs"
fi

resolve() { git -C "$WF_ROOT" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null; }
show() { git -C "$WF_ROOT" show "$SRC_SHA:$1" 2>/dev/null; }

# ---- the revision of this repository the files come from ---------------------
SRC_NOTE=""
if [ "$MODE" = ref ]; then
  if [[ ! "$REF" =~ ^v[0-9]+$ && ! "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && ! "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    usage_die "--mode ref needs a version tag (v10, v10.0.0) or a full 40-character commit sha, not '$REF': a branch would follow unreleased changes"
  fi
  if [ -n "$FROM" ]; then
    SRC_SHA="$(resolve "$FROM")" || die "--from '$FROM' is not a revision of $WF_ROOT"
    SRC_NOTE="templates from --from $FROM"
  elif SRC_SHA="$(resolve "$REF")"; then
    SRC_NOTE="templates from $REF"
  else
    SRC_SHA="$(resolve HEAD)" || die "cannot resolve HEAD in $WF_ROOT"
    SRC_NOTE="templates from HEAD: $REF is not in this clone, the tag is not created or not fetched yet"
  fi
else
  [ -z "$FROM" ] || usage_die "--from is for --mode ref; vendor mode copies everything from --ref itself"
  SRC_SHA="$(resolve "$REF")" || die "cannot vendor '$REF': no such tag, branch or commit in $WF_ROOT (git fetch --tags first)"
  SRC_NOTE="logic and templates from $REF"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wf-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/out"

# ---- stub templates and their contract version -------------------------------
CONTRACT=""
for f in $FILES; do
  show "stubs/$STACK/$f.yml" > "$STAGE/stub-$f.yml" \
    || die "stubs/$STACK/$f.yml does not exist at $SRC_SHA (unknown --stack, or a revision before contract v10)"
  n="$(sed -n "1s/^# emergy\.cloud workflow contract: $STACK v\([0-9][0-9]*\)\$/\1/p" "$STAGE/stub-$f.yml")"
  [ -n "$n" ] || die "stubs/$STACK/$f.yml at $SRC_SHA has no contract marker on line 1"
  if [ -z "$CONTRACT" ]; then CONTRACT="$n"; elif [ "$n" != "$CONTRACT" ]; then die "stubs/$STACK at $SRC_SHA mix contract v$CONTRACT and v$n"; fi
done
if [[ "$REF" =~ ^v([0-9]+) ]] && [ "${BASH_REMATCH[1]}" != "$CONTRACT" ]; then
  die "--ref $REF is contract v${BASH_REMATCH[1]} but the stub templates read from $SRC_SHA are v$CONTRACT; pass --from <a v${BASH_REMATCH[1]} revision> or fetch the tags"
fi

# ---- the ENVS fallback ------------------------------------------------------
if [ -n "$ENVS_ARG" ]; then
  RAW_ENVS="$ENVS_ARG"; ENVS_SRC="--envs"
else
  RAW_ENVS=""
  if [ -f "$TARGET_ABS/.github/workflows/build.yml" ]; then
    RAW_ENVS="$(sed -n "s/.*vars\.ENVS || '\([a-z,]*\)'.*/\1/p" "$TARGET_ABS/.github/workflows/build.yml" | head -1)"
  fi
  if [ -n "$RAW_ENVS" ]; then ENVS_SRC="the target's current build.yml"; else RAW_ENVS="dev,staging,prod"; ENVS_SRC="default"; fi
fi
RAW_ENVS="$(printf '%s' "$RAW_ENVS" | tr -d ' ')"
OLD_IFS="$IFS"; IFS=','
set -f
for e in $RAW_ENVS; do
  [ -n "$e" ] || continue
  case " $CONTRACT_ENVS " in *" $e "*) ;; *) IFS="$OLD_IFS"; die "--envs: '$e' is not a contract environment (dev, staging, prod)" ;; esac
done
set +f
IFS="$OLD_IFS"
ENVS=""
for e in $CONTRACT_ENVS; do
  case ",$RAW_ENVS," in *",$e,"*) ENVS="${ENVS:+$ENVS,}$e" ;; esac
done
[ -n "$ENVS" ] || die "--envs: no environment given"

# ---- render ------------------------------------------------------------------
for f in $FILES; do
  call="emergy-cloud/workflows/\.github/workflows/$f\.yml@v$CONTRACT"
  if [ "$MODE" = ref ]; then
    to="emergy-cloud/workflows/.github/workflows/$f.yml@$REF"
  else
    to="./.github/workflows/vendored-$f.yml"
  fi
  sed -e "s#^\([[:space:]]*uses:[[:space:]]*\)$call\$#\1$to#" \
      -e "s/vars\.ENVS || 'dev,staging,prod'/vars.ENVS || '$ENVS'/g" \
      "$STAGE/stub-$f.yml" > "$STAGE/out/$f.yml"
  calls="$(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$STAGE/out/$f.yml" | sed 's/^[[:space:]]*//' || true)"
  [ "$calls" = "uses: $to" ] || die "stubs/$STACK/$f.yml at $SRC_SHA does not call emergy-cloud/workflows/.github/workflows/$f.yml@v$CONTRACT exactly once"
  if [ "$MODE" = vendor ]; then
    show ".github/workflows/$f.yml" > "$STAGE/logic-$f.yml" || die ".github/workflows/$f.yml does not exist at $SRC_SHA"
    [ "$(head -1 "$STAGE/logic-$f.yml")" = "# emergy.cloud workflow contract: $STACK v$CONTRACT (shared logic)" ] \
      || die ".github/workflows/$f.yml at $SRC_SHA is not the $STACK v$CONTRACT logic its stub calls"
    {
      echo "# vendored from $THIS_REPO@$REF ($SRC_SHA): do not edit, refresh with scripts/install.sh"
      cat "$STAGE/logic-$f.yml"
    } > "$STAGE/out/vendored-$f.yml"
  fi
done

# A vendored repository must not depend on this one: no `uses:` into it, no
# checkout of it, no script fetched from it (comments may name the source).
if [ "$MODE" = vendor ]; then
  if hits="$(grep -nE '^[^#]*emergy-cloud/workflows' "$STAGE"/out/*.yml)"; then
    die "vendored output still references $THIS_REPO outside comments:
$hits"
  fi
fi

# ---- write -------------------------------------------------------------------
echo "emergy.cloud CI install: mode=$MODE ref=$REF contract=$STACK v$CONTRACT"
echo "  source: $THIS_REPO@$SRC_SHA ($SRC_NOTE)"
echo "  envs fallback: $ENVS (from $ENVS_SRC)"
echo "  target: $TARGET_ABS"
mkdir -p "$TARGET_ABS/.github/workflows"
for f in $FILES; do
  cp "$STAGE/out/$f.yml" "$TARGET_ABS/.github/workflows/$f.yml"
  if [ "$MODE" = ref ]; then
    echo "wrote .github/workflows/$f.yml (stub, calls $THIS_REPO/.github/workflows/$f.yml@$REF)"
  else
    echo "wrote .github/workflows/$f.yml (stub, calls ./.github/workflows/vendored-$f.yml)"
  fi
done
if [ "$MODE" = vendor ]; then
  for f in $FILES; do
    cp "$STAGE/out/vendored-$f.yml" "$TARGET_ABS/.github/workflows/vendored-$f.yml"
    echo "wrote .github/workflows/vendored-$f.yml (logic vendored from $THIS_REPO@$REF, $SRC_SHA)"
  done
else
  for f in $FILES; do
    if [ -f "$TARGET_ABS/.github/workflows/vendored-$f.yml" ]; then
      echo "note: .github/workflows/vendored-$f.yml is left in place but no longer called; delete it in the same commit"
    fi
  done
fi
echo "Review with: git -C $TARGET_ABS diff -- .github/workflows; then commit."
