#!/bin/bash
# release.sh — lien-release が使う xcodebuild の呼び出し(issue #28)
#
#   archive-unsigned   無署名の archive(dry-run。署名・アップロードはしない)
#   archive-signed     ASC API キーのクラウド署名で archive
#   export-upload      archive を書き出し、App Store Connect(TestFlight)へアップロード
#
# 環境変数:
#   BUILD_NUMBER (必須)  CFBundleVersion。lien-release は github.run_number(同じ版の中で単調増加が必要)
#   ARCHIVE_PATH         .xcarchive の場所(既定: $RUNNER_TEMP/Lien.xcarchive)
#   署名つきのとき(archive-signed / export-upload):
#     ASC_KEY_PATH       App Store Connect API キー(.p8)のファイルのパス
#     ASC_KEY_ID / ASC_ISSUER_ID / APPLE_TEAM_ID
#   RELEASE_PRINT_ONLY=1  実行せず、実行するはずのコマンドを表示するだけ(dry-run が署名経路の組み立てを確かめる)
#
# ios/ で xcodegen generate と scripts/pin-packages.sh を済ませてから呼ぶ。
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_DIR"

TMP_BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$TMP_BASE/Lien.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$TMP_BASE/LienExport}"
PRINT_ONLY="${RELEASE_PRINT_ONLY:-0}"

die() { echo "::error::$*"; exit 1; }

# コマンドを表示してから実行する(PRINT_ONLY=1 なら表示だけ)
run() {
  printf '+'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
  if [ "$PRINT_ONLY" = "1" ]; then return 0; fi
  "$@"
}

require_build_number() {
  [ -n "${BUILD_NUMBER:-}" ] || die "BUILD_NUMBER が未設定です"
  case "$BUILD_NUMBER" in
    *[!0-9]* | '') die "BUILD_NUMBER は整数にしてください(${BUILD_NUMBER})" ;;
  esac
}

require_signing_env() {
  [ -n "${ASC_KEY_PATH:-}" ] || die "ASC_KEY_PATH(.p8 のパス)が未設定です"
  [ -n "${ASC_KEY_ID:-}" ] || die "ASC_KEY_ID が未設定です"
  [ -n "${ASC_ISSUER_ID:-}" ] || die "ASC_ISSUER_ID が未設定です"
  [ -n "${APPLE_TEAM_ID:-}" ] || die "APPLE_TEAM_ID が未設定です"
  case "$APPLE_TEAM_ID" in
    *[!A-Z0-9]* | '') die "APPLE_TEAM_ID は 10 桁の英数字(大文字)です" ;;
  esac
  [ "${#APPLE_TEAM_ID}" -eq 10 ] || die "APPLE_TEAM_ID は 10 桁の英数字です"
  if [ "$PRINT_ONLY" != "1" ] && [ ! -f "$ASC_KEY_PATH" ]; then
    die "ASC API キーのファイルがありません"
  fi
}

# archive に共通の引数。リリースは Release 構成・実機向け(generic/platform=iOS)・Package.resolved の固定を必ず使う
archive_args() {
  ARCHIVE_ARGS=(
    -project Lien.xcodeproj
    -scheme Lien
    -configuration Release
    -destination 'generic/platform=iOS'
    -archivePath "$ARCHIVE_PATH"
    -onlyUsePackageVersionsFromResolvedFile
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  )
}

# ASC API キーによるクラウド署名の引数(-allowProvisioningUpdates で証明書・プロファイル・App ID・App Group を Apple 側に任せる)
auth_args() {
  AUTH_ARGS=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
}

cmd_archive_unsigned() {
  require_build_number
  archive_args
  run xcodebuild archive "${ARCHIVE_ARGS[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
}

cmd_archive_signed() {
  require_build_number
  require_signing_env
  archive_args
  auth_args
  run xcodebuild archive "${ARCHIVE_ARGS[@]}" "${AUTH_ARGS[@]}" \
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic
}

cmd_export_upload() {
  require_signing_env
  auth_args
  local options="$TMP_BASE/ExportOptions.plist"
  cp Config/ExportOptions.plist "$options"
  # teamID の雛形(REPLACE_WITH_APPLE_TEAM_ID)を、secrets の値に差し替える
  plutil -replace teamID -string "$APPLE_TEAM_ID" "$options"
  plutil -lint "$options" >/dev/null
  run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$options" \
    -exportPath "$EXPORT_PATH" \
    "${AUTH_ARGS[@]}"
}

case "${1:-}" in
  archive-unsigned) cmd_archive_unsigned ;;
  archive-signed) cmd_archive_signed ;;
  export-upload) cmd_export_upload ;;
  *) echo "使い方: $0 archive-unsigned | archive-signed | export-upload" >&2; exit 2 ;;
esac
