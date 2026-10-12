#!/bin/bash
# pin-packages.sh — コミット済みの Package.resolved を生成した .xcodeproj へ戻し、解決結果がずれていないか確かめる(issue #28)
#
# .xcodeproj は xcodegen が毎回作り直す(コミットしない)ので、SwiftPM の解決結果(Package.resolved)も
# 一緒に消える。そのままだと supabase-swift 以外の推移依存(swift-crypto など)が、ビルドのたびに
# 「その時点の最新」に解決されてしまう。そこで ios/Package.resolved をコミットしておき、
# xcodegen generate の直後にこのスクリプトで .xcodeproj へ戻す。
# 以降の xcodebuild は -onlyUsePackageVersionsFromResolvedFile を付けて、この固定を必ず使う。
#
# project.yml の版を変えたのに Package.resolved が古いと、ここで止まり、貼るべき新しい内容を出力する。
#
# 使い方(ios/ で xcodegen generate をした後): scripts/pin-packages.sh
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_DIR"

DEST="Lien.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$DEST"
cp Package.resolved "$DEST/Package.resolved"

echo "::group::xcodebuild -resolvePackageDependencies"
xcodebuild -resolvePackageDependencies -project Lien.xcodeproj -scheme Lien
echo "::endgroup::"

python3 scripts/package_resolved.py compare Package.resolved "$DEST/Package.resolved"
