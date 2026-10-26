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

# 書き出しは手動署名にする。クラウド署名(-allowProvisioningUpdates)は archive までは通るが、
# 配布用プロファイルの作成が「Cloud signing permission error」で弾かれる環境があるため、
# 証明書とプロファイルを secrets から入れ、ExportOptions で明示的に指定する。
require_export_env() {
  [ -n "${IOS_DIST_CERT_P12:-}" ] || die "IOS_DIST_CERT_P12(配布用証明書の p12 を base64 にしたもの)が未設定です"
  [ -n "${IOS_DIST_CERT_PASSWORD:-}" ] || die "IOS_DIST_CERT_PASSWORD が未設定です"
  local name
  for name in IOS_PROFILE_UUID_APP IOS_PROFILE_UUID_WIDGET IOS_PROFILE_UUID_NSE; do
    [ -n "${!name:-}" ] || die "$name(App Store 用プロファイルの UUID)が未設定です"
  done
}

# 配布用証明書を一時キーチェーンへ入れる(ランナーの既定キーチェーンを汚さない)
import_distribution_cert() {
  local keychain="$TMP_BASE/Lien-signing.keychain-db"
  local p12="$TMP_BASE/distribution.p12"
  printf '%s' "$IOS_DIST_CERT_P12" | base64 --decode >"$p12"
  run security create-keychain -p "" "$keychain"
  run security set-keychain-settings -lut 3600 "$keychain"
  run security unlock-keychain -p "" "$keychain"
  run security import "$p12" -k "$keychain" -P "$IOS_DIST_CERT_PASSWORD" -T /usr/bin/codesign
  run security set-key-partition-list -S apple-tool:,apple: -k "" "$keychain"
  # 既存のキーチェーンは残したまま、一時キーチェーンを先頭に足す
  local existing
  existing="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  run security list-keychains -d user -s "$keychain" $existing
}

cmd_export_upload() {
  require_signing_env
  require_export_env
  auth_args
  import_distribution_cert
  local options="$TMP_BASE/ExportOptions.plist"
  cp Config/ExportOptions.plist "$options"
  # teamID の雛形(REPLACE_WITH_APPLE_TEAM_ID)を、secrets の値に差し替える
  plutil -replace teamID -string "$APPLE_TEAM_ID" "$options"
  # 手動署名へ切り替え、3 バンドルぶんのプロファイルを明示する
  plutil -replace signingStyle -string manual "$options"
  plutil -insert provisioningProfiles -json "$(printf '{"com.ryoki63.lien":"%s","com.ryoki63.lien.widget":"%s","com.ryoki63.lien.nse":"%s"}' \
    "$IOS_PROFILE_UUID_APP" "$IOS_PROFILE_UUID_WIDGET" "$IOS_PROFILE_UUID_NSE")" "$options"
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
