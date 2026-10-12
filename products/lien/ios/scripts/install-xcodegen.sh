#!/bin/bash
# install-xcodegen.sh — XcodeGen を、版と SHA-256 を固定して入れる(issue #66)
#
# `brew install xcodegen` は「その時点の最新」が入る。XcodeGen が上がるたびに、同じコミットから作る
# .xcodeproj が(気づかないうちに)変わりうる。そこで GitHub の公式リリースの zip を、版と SHA-256 を固定して入れる。
# lien-ios(テスト)と lien-release(archive)の両方が、このスクリプトを使う。
#
#   scripts/install-xcodegen.sh
#
# 入れた先の bin を $GITHUB_PATH に足すので、後続のステップで `xcodegen` がそのまま使える。
# 版と SHA-256 を上げるとき(2 か所):
#   1. 新しい版のリリースの `xcodegen.zip` の SHA-256 を、API の digest で確かめる(ダウンロードして計算するより確実):
#        gh api repos/yonaskolb/XcodeGen/releases/tags/<版> --jq '.assets[] | select(.name=="xcodegen.zip") | .digest'
#   2. 下の XCODEGEN_VERSION と XCODEGEN_SHA256 を書き換える
#   生成される .xcodeproj が変わりうるので、lien-ios が緑になるのを確かめてから取り込む。
#
# zip の中身(XcodeGen の scripts/archive.sh): xcodegen/bin/xcodegen と xcodegen/share/xcodegen/SettingPresets/。
# xcodegen は、実行ファイルの隣の ../share/xcodegen/SettingPresets を読むので、この配置のまま使う(動かさない)。
#
# 環境変数(テスト用。lien-ios・lien-release は設定しない):
#   XCODEGEN_VERSION / XCODEGEN_SHA256   固定する版と SHA-256(既定は下の値)
#   XCODEGEN_URL                         zip の場所(既定は GitHub のリリース。file:// も可)
set -euo pipefail

XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.46.0}"
XCODEGEN_SHA256="${XCODEGEN_SHA256:-4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806}"
XCODEGEN_URL="${XCODEGEN_URL:-https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip}"

die() { echo "::error::$*"; exit 1; }

TMP_BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
DEST="${TMP_BASE%/}/xcodegen-${XCODEGEN_VERSION}"
ZIP="${TMP_BASE%/}/xcodegen-${XCODEGEN_VERSION}.zip"

rm -rf "$DEST" "$ZIP"
mkdir -p "$DEST"

echo "XcodeGen ${XCODEGEN_VERSION} をダウンロードします: ${XCODEGEN_URL}"
curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --output "$ZIP" "$XCODEGEN_URL" \
  || die "XcodeGen ${XCODEGEN_VERSION} をダウンロードできません(${XCODEGEN_URL})"

ACTUAL_SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
if [ "$ACTUAL_SHA256" != "$XCODEGEN_SHA256" ]; then
  rm -f "$ZIP"
  die "XcodeGen の zip の SHA-256 が固定した値と違います(期待: ${XCODEGEN_SHA256} / 実際: ${ACTUAL_SHA256})。使いません"
fi
echo "SHA-256: 一致"

unzip -q -o "$ZIP" -d "$DEST" || die "XcodeGen の zip を展開できません"
rm -f "$ZIP"

BIN_DIR="$DEST/xcodegen/bin"
[ -x "$BIN_DIR/xcodegen" ] || die "${BIN_DIR}/xcodegen がありません(zip の中身が想定と違います)"
[ -f "$DEST/xcodegen/share/xcodegen/SettingPresets/base.yml" ] \
  || die "SettingPresets がありません(xcodegen は ../share/xcodegen/SettingPresets を読みます)"

VERSION_OUTPUT="$("$BIN_DIR/xcodegen" --version 2>&1)" || die "xcodegen --version が失敗しました: ${VERSION_OUTPUT}"
case "$VERSION_OUTPUT" in
  *"${XCODEGEN_VERSION}"*) ;;
  *) die "xcodegen --version が ${XCODEGEN_VERSION} ではありません: ${VERSION_OUTPUT}" ;;
esac
echo "xcodegen --version: ${VERSION_OUTPUT}"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
else
  echo "PATH に足してください: export PATH=\"${BIN_DIR}:\$PATH\""
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## XcodeGen"
    echo
    echo "- 版: \`${XCODEGEN_VERSION}\`(\`xcodegen --version\`: \`${VERSION_OUTPUT}\`)"
    echo "- zip の SHA-256 を固定した値と照合済み(\`scripts/install-xcodegen.sh\`)"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi
