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

bash scripts/setup_wince.sh

SYSTEM_NAME="$(sed -n 's/.*-DCMAKE_SYSTEM_NAME=\([^[:space:]]*\).*/\1/p' scripts/build_wince.sh | head -1)"
[ -n "$SYSTEM_NAME" ] || SYSTEM_NAME="WindowsCE"

mkdir -p wince
cd wince

cmake \
  -DTARGET_ARCH=arm-mingw32ce -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
  -DCMAKE_TOOLCHAIN_FILE=../Toolchain/mingw.cmake \
  -DXSLTS=windows,wince -DCACHE_SIZE=10485760 -Dsvg2png_scaling:STRING=16,32 \
  -Dsvg2png_scaling_nav:STRING=32 -Dsvg2png_scaling_flag=16 -DSAMPLE_MAP=y ..
make VERBOSE=1

# Some older refs enable the sample map at build time but never copy the
# generated files into wince/output/. Normalize the package layout here.
rm -rf output
mkdir -p output/maps
cp navit/navit.exe output/
cp navit/navit.xml output/
cp navit/navit_layout*.xml output/ 2>/dev/null || true
cp -r locale/ output/
cp -r navit/icons/ output/
cp -r ../navit/support/espeak/espeak-data/ output/ 2>/dev/null || true
cp navit/maps/*.bin output/maps/ 2>/dev/null || true
cp navit/maps/*.xml output/maps/ 2>/dev/null || true
rm -rf output/icons/CMakeFiles/ icons/cmake_install.cmake

mkdir -p "$ARTIFACT_DIR"
cp -a output/. "$ARTIFACT_DIR/"
git rev-parse HEAD > "$ARTIFACT_DIR/COMMIT_SHA"
printf "%s\n" "$TARGET_REF" > "$ARTIFACT_DIR/SOURCE_REF"
