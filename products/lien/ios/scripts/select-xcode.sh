#!/bin/bash
# select-xcode.sh — ios/.xcode-version に書いた Xcode を使い、iOS 26 SDK 以上であることを確かめる(issue #28)
#
# 2026-04-28 以降、App Store Connect へのアップロードは Xcode 26 / iOS 26 SDK 以上でビルドしたものだけが
# 受け付けられる。lien-ios(テスト)と lien-release(archive)が必ず同じ版を使うよう、版は
# ios/.xcode-version の 1 か所にだけ書く。ランナーに入っている版は actions/runner-images の
# images/macos/macos-26-arm64-Readme.md で確かめる(2026-10 時点: macos-26 に 26.0.1〜26.6)。
#
# 使い方:
#   scripts/select-xcode.sh                     GitHub Actions: sudo xcode-select -s で切り替えてから検査
#   DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer scripts/select-xcode.sh
#                                               ローカル: 切り替えない。いまの Xcode が要件を満たすかだけ検査
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WANT="$(tr -d '[:space:]' < "$IOS_DIR/.xcode-version")"
MIN_SDK_MAJOR=26

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  APP="/Applications/Xcode_${WANT}.app"
  if [ ! -d "$APP" ]; then
    echo "::error::${APP} がありません。このランナーにある Xcode: $(ls -d /Applications/Xcode_*.app 2>/dev/null | tr '\n' ' ')"
    echo "::error::ios/.xcode-version を、ランナーイメージにある版へ直してください(lien-ios と lien-release は同じ版を使います)"
    exit 1
  fi
  sudo xcode-select -s "${APP}/Contents/Developer"
fi

xcodebuild -version
ACTUAL="$(xcodebuild -version | awk 'NR==1 { print $2 }')"
if [ "$ACTUAL" != "$WANT" ]; then
  echo "::error::Xcode ${ACTUAL} が選ばれています(ios/.xcode-version は ${WANT})。ローカルなら DEVELOPER_DIR で ${WANT} を指定してください"
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "iphoneos SDK: ${SDK}"
echo "swift: $(xcrun swift --version 2>&1 | head -n 1)"
if [ "${SDK%%.*}" -lt "$MIN_SDK_MAJOR" ]; then
  echo "::error::iOS SDK ${SDK} は ${MIN_SDK_MAJOR} 未満です。App Store Connect は iOS ${MIN_SDK_MAJOR} SDK 以上を要求します"
  exit 1
fi
