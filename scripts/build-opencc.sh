#!/usr/bin/env bash
# Builds a static, universal OpenCC library plus its compiled dictionaries into Vendor/opencc.
set -euo pipefail

OPENCC_TAG="${OPENCC_TAG:-ver.1.4.2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build-opencc"
PREFIX="$ROOT/Vendor/opencc"

rm -rf "$WORK" "$PREFIX"
git clone --quiet --depth 1 --branch "$OPENCC_TAG" https://github.com/BYVoid/OpenCC "$WORK/src"

cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DOPENCC_ENABLE_INSTALL=ON \
  -DENABLE_GTEST=OFF -DENABLE_BENCHMARK=OFF -DBUILD_PYTHON=OFF \
  -DBUILD_OPENCC_JIEBA_PLUGIN=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$WORK/build"
cmake --install "$WORK/build"

# Keep only what the app needs: headers, static libs, and the s2twp config + dictionaries.
mkdir -p "$PREFIX/dict"
cp "$PREFIX"/share/opencc/s2twp.json "$PREFIX/dict/"
for d in CJK_Compatibility_Ideographs STPhrases STPhrases_GeneratedFromRegionalPhrases STCharacters \
         TWPhrases TWVariantsPhrases TWVariants; do
  cp "$PREFIX/share/opencc/$d.ocd2" "$PREFIX/dict/"
done
echo "OpenCC $OPENCC_TAG installed to $PREFIX"
