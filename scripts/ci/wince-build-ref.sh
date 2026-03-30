#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <git-ref> <label>" >&2
    exit 64
fi

TARGET_REF="$1"
LABEL="$2"
ROOT_DIR="$PWD"
WORKTREE_ROOT="$ROOT_DIR/.wince-ref-worktrees"
WORKTREE_DIR="$WORKTREE_ROOT/$LABEL"
ARTIFACT_ROOT="$ROOT_DIR/wince-ref-artifacts"
ARTIFACT_DIR="$ARTIFACT_ROOT/$LABEL"

cleanup() {
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
    rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT

mkdir -p "$WORKTREE_ROOT" "$ARTIFACT_ROOT"
git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
rm -rf "$WORKTREE_DIR" "$ARTIFACT_DIR"

git worktree add --force --detach "$WORKTREE_DIR" "$TARGET_REF"

cd "$WORKTREE_DIR"
echo "[wince-build-ref] Building $(git rev-parse HEAD) from $TARGET_REF"

# Older refs ship SAMPLE_MAP=n by default. Flip it on here so the smoke test
# actually exercises binfile loading for the regression comparison.
if grep -q -- "-DSAMPLE_MAP=n" scripts/build_wince.sh; then
    sed -i "s/-DSAMPLE_MAP=n/-DSAMPLE_MAP=y/g" scripts/build_wince.sh
fi

bash scripts/setup_wince.sh
bash scripts/build_wince.sh

# Some older refs enable the sample map at build time but never copy the
# generated files into wince/output/. Normalize the package layout here.
mkdir -p wince/output/maps
cp wince/navit/maps/*.bin wince/output/maps/ 2>/dev/null || true
cp wince/navit/maps/*.xml wince/output/maps/ 2>/dev/null || true

mkdir -p "$ARTIFACT_DIR"
cp -a wince/output/. "$ARTIFACT_DIR/"
git rev-parse HEAD > "$ARTIFACT_DIR/COMMIT_SHA"
printf "%s\n" "$TARGET_REF" > "$ARTIFACT_DIR/SOURCE_REF"
