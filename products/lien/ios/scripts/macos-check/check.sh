#!/bin/bash
# check.sh — Xcode が無い Mac(Command Line Tools だけ)で、push の前に「コンパイルできる・テストが緑」を確かめる補助
# (仕組み・限界は README.md。CI の lien-ios が正本で、これは数十秒で回る手元の下見)
#
#   check.sh [all]            build + test + views
#   check.sh build            UIKit / Supabase に依存しない部分を macOS 用の module "Lien" としてビルド
#   check.sh test [名前...]   build して LienTests を走らせる(名前は LienTests/ のファイル名(拡張子なし)。省略で除外以外すべて)
#   check.sh views            SwiftUI の View と AppServices+Live を macOS の SDK で型検査する(Swift の並行性の厳密な検査つき)
#   check.sh widget           LienWidget ターゲット(WidgetKit の拡張)を、project.yml の sources のとおりに集めて型検査する
#                             (ロック画面の accessory 系ファミリーは macOS の SDK に無いので、型検査用のコピーでだけ別のファミリーに読み替える)
#
# 環境変数:  ONLY=<正規表現>   test で "クラス名.メソッド名" を絞る(例: ONLY='PartnerPhotoModel')
#            VERBOSE=1         test で PASS の行も出す
#            MACOS_CHECK_OUT   作業ディレクトリ(既定: $TMPDIR/lien-macos-check。リポジトリの外)
# 終了コード: 0 = すべて通った / 1 = コンパイルエラー・テスト失敗
#
# bash 3.2(macOS 標準)で動くように書いてある(連想配列・mapfile を使わない)。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
IOS="$(cd "$HERE/../.." && pwd)"
OUT="${MACOS_CHECK_OUT:-${TMPDIR:-/tmp}/lien-macos-check}"
mkdir -p "$OUT"

SDK="$(xcrun --show-sdk-path 2>/dev/null)"
if [ -z "$SDK" ]; then
  echo "xcrun --show-sdk-path が空です。Command Line Tools を入れてください(xcode-select --install)" >&2
  exit 1
fi
TARGET="$(uname -m)-apple-macos14.0"
COMMON=(-swift-version 5 -sdk "$SDK" -target "$TARGET")

# ---------------------------------------------------------------------------------------------
# macOS では動かせない / UIKit・Supabase・描画に依存するもの(ここを変えたら README も)
# ---------------------------------------------------------------------------------------------

# module "Lien" に含めない(Lien/ からの相対パス)。View は views で別に型検査する
exclude_from_module() {
  case "$1" in
    Lien/App/AppDelegate.swift) return 0 ;;                 # UIKit・UserNotifications
    Lien/App/LienApp.swift) return 0 ;;                     # @main
    Lien/App/RootView.swift) return 0 ;;                    # iOS 専用の API(navigationBarTitleDisplayMode など)
    Lien/App/AppServices+Live.swift) return 0 ;;            # supabase-swift(views で stubs/LiveStubs.swift を付けて型検査する)
    Lien/Core/SupabaseService.swift) return 0 ;;            # supabase-swift
    Lien/Core/Purchases/RevenueCatPurchasesClient.swift) return 0 ;; # RevenueCat SDK(CI の iOS ビルドだけ)
    Lien/Core/PushManager.swift) return 0 ;;                # UIKit・UserNotifications(stubs/PushAuthorizingStub.swift が代わり)
    Lien/Core/DesignSystem/Colors.swift) return 0 ;;        # UIKit(views で macOS 用に書き換えて型検査する)
    Lien/Core/DesignSystem/PlantCharacterView.swift) return 0 ;;  # SwiftUI の View
    Lien/Core/Widget/Views/*) return 0 ;;                   # SwiftUI の View(ウィジェットの S / M / ロック画面。views で型検査する)
    Lien/Features/Debug/*) return 0 ;;                      # UIKit
    Lien/Features/Pairing/QRCodeGenerator.swift) return 0 ;; # UIImage
    Lien/Features/*View.swift|Lien/Features/*Sheet.swift) return 0 ;; # SwiftUI の View
  esac
  return 1
}

# 走らせないテスト(LienTests/ のファイル名)。理由:
#   AppServicesTests / ConfigTests : AppServices+Live.swift(supabase-swift)を使う
#   PlantRenderTests / PlantLayersTests / HomeRenderChecksTests / NotificationSettingsRenderTests / WidgetRenderTests(と、その道具 WidgetRenderSupport): アセットカタログ・SwiftUI の描画・UIKit のウィンドウと色・XCTAttachment を使う
#   ShareImageRenderTests : シェア画像の実描画(ImageRenderer・アセットカタログ・XCTAttachment)。T22
#   DeviceTokenStoreTests : AppDelegate.swift(UIKit)を使う
#   QRCodeGeneratorTests : QRCodeGenerator.swift(UIImage)を使う
#   SmokeTests : アプリ本体のバンドルの前提
EXCLUDE_TESTS="AppServicesTests ConfigTests PlantRenderTests PlantLayersTests HomeRenderChecksTests NotificationSettingsRenderTests WidgetRenderTests WidgetRenderSupport ShareImageRenderTests PaywallRenderTests DeviceTokenStoreTests QRCodeGeneratorTests SmokeTests"

is_excluded_test() {
  local name="$1" e
  for e in $EXCLUDE_TESTS; do [ "$e" = "$name" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------------------------
# 道具
# ---------------------------------------------------------------------------------------------

# swiftc が使えるか確かめる。Command Line Tools の一部の版は、Foundation を import するだけで
# 「redefinition of module 'SwiftBridging'」で落ちる(include/swift に modulemap が2つある)。
# その場合は、古い方の module.modulemap を空のファイルに見せる VFS overlay を付けて回避する
prepare_toolchain() {
  printf 'import Foundation\n' > "$OUT/probe.swift"
  if swiftc -typecheck "${COMMON[@]}" "$OUT/probe.swift" > "$OUT/probe.log" 2>&1; then
    return 0
  fi
  if grep -q "redefinition of module 'SwiftBridging'" "$OUT/probe.log"; then
    local include_dir
    include_dir="$(xcode-select -p)/usr/include/swift"
    : > "$OUT/empty.modulemap"
    cat > "$OUT/overlay.yaml" <<YAML
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "type": "directory",
      "name": "$include_dir",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$OUT/empty.modulemap" }
      ]
    }
  ]
}
YAML
    COMMON+=(-vfsoverlay "$OUT/overlay.yaml")
    if swiftc -typecheck "${COMMON[@]}" "$OUT/probe.swift" > "$OUT/probe.log" 2>&1; then
      echo "(Command Line Tools の SwiftBridging の二重定義を VFS overlay で回避しています)"
      return 0
    fi
  fi
  cat "$OUT/probe.log"
  echo "swiftc で Foundation を import できません。上のエラーを確かめてください" >&2
  return 1
}

# コンパイラの出力から、error / warning の行だけを(リポジトリ内のパスを短くして)出す
show_diagnostics() {
  grep -E "^(/|<unknown>).*: (error|warning):" "$1" | sed "s#$IOS/##" | sort | uniq | head -${2:-40}
}

# ---------------------------------------------------------------------------------------------
# build: module "Lien"(+ XCTest 互換)
# ---------------------------------------------------------------------------------------------

do_build() {
  prepare_toolchain || return 1

  swiftc "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name XCTest \
    -o "$OUT/libXCTest.a" -emit-module-path "$OUT/XCTest.swiftmodule" "$HERE/XCTestShim.swift" \
    > "$OUT/xctest.log" 2>&1 || { cat "$OUT/xctest.log"; echo "XCTest 互換のビルドに失敗" >&2; return 1; }

  local files=() f rel
  while IFS= read -r f; do
    rel="${f#$IOS/}"
    exclude_from_module "$rel" && continue
    files+=("$f")
  done < <(find "$IOS/Lien" -name '*.swift' | sort)
  files+=("$HERE/stubs/PushAuthorizingStub.swift")

  swiftc "${COMMON[@]}" -parse-as-library -emit-library -static -enable-testing -emit-module -module-name Lien \
    -I "$OUT" -o "$OUT/libLien.a" -emit-module-path "$OUT/Lien.swiftmodule" "${files[@]}" > "$OUT/lien.log" 2>&1
  local status=$?
  show_diagnostics "$OUT/lien.log"
  if [ $status -ne 0 ]; then
    echo "module Lien のビルドに失敗(${#files[@]} ファイル)" >&2
    return 1
  fi
  echo "module Lien OK(${#files[@]} ファイル)"
}

# ---------------------------------------------------------------------------------------------
# test: LienTests を macOS で走らせる
# ---------------------------------------------------------------------------------------------

do_test() {
  do_build || return 1

  local tests=() f name
  if [ $# -gt 0 ]; then
    for name in "$@"; do
      f="$IOS/LienTests/$name.swift"
      [ -f "$f" ] || { echo "LienTests/$name.swift がありません" >&2; return 1; }
      tests+=("$f")
    done
    # 共通の道具は常に含める
    tests+=("$IOS/LienTests/TestSupport.swift" "$IOS/LienTests/SourceTree.swift")
  else
    while IFS= read -r f; do
      name="$(basename "$f" .swift)"
      is_excluded_test "$name" && continue
      tests+=("$f")
    done < <(find "$IOS/LienTests" -name '*.swift' | sort)
  fi
  # 重複を除く(名前指定で TestSupport などを選んだとき)
  local unique=() t u dup
  for t in "${tests[@]}"; do
    dup=0
    for u in ${unique[@]+"${unique[@]}"}; do [ "$u" = "$t" ] && dup=1; done
    [ $dup -eq 0 ] && unique+=("$t")
  done

  python3 "$HERE/gen_runner.py" "$OUT/main.swift" "${unique[@]}" || return 1

  swiftc "${COMMON[@]}" -I "$OUT" -L "$OUT" -lLien -lXCTest -o "$OUT/runner" "${unique[@]}" "$OUT/main.swift" \
    > "$OUT/tests.log" 2>&1
  local status=$?
  show_diagnostics "$OUT/tests.log" | grep -v "main.swift"
  if [ $status -ne 0 ]; then
    echo "テストのコンパイルに失敗" >&2
    return 1
  fi

  (cd "$IOS" && "$OUT/runner") > "$OUT/test.out" 2>&1
  status=$?
  if [ "${VERBOSE:-0}" = "1" ]; then cat "$OUT/test.out"; else grep -v "^PASS " "$OUT/test.out"; fi
  return $status
}

# ---------------------------------------------------------------------------------------------
# views: SwiftUI の View と AppServices+Live の型検査
# ---------------------------------------------------------------------------------------------

do_views() {
  prepare_toolchain || return 1

  # Colors.swift は UIKit の色を使うので、macOS の色に書き換えたコピーを型検査に使う
  mkdir -p "$OUT/views_src"
  sed -e 's/import UIKit/import AppKit/' \
      -e 's/Color(uiColor: *\.[A-Za-z]*)/Color(nsColor: .controlBackgroundColor)/g' \
      "$IOS/Lien/Core/DesignSystem/Colors.swift" > "$OUT/views_src/Colors.swift"

  local files=() f rel
  while IFS= read -r f; do
    rel="${f#$IOS/}"
    case "$rel" in
      # UIKit・@main・iOS 専用の画面は型検査の対象にしない
      Lien/App/AppDelegate.swift|Lien/App/LienApp.swift|Lien/App/RootView.swift) continue ;;
      Lien/Core/SupabaseService.swift|Lien/Core/PushManager.swift|Lien/Core/DesignSystem/Colors.swift) continue ;;
      Lien/Core/Purchases/RevenueCatPurchasesClient.swift) continue ;; # RevenueCat SDK(CI の iOS ビルドだけ)
      Lien/Features/Debug/*|Lien/Features/Pairing/QRCodeGenerator.swift) continue ;;
      Lien/Features/Onboarding/*View.swift|Lien/Features/Pairing/*View.swift|Lien/Features/PromiseSetup/*View.swift) continue ;;
    esac
    files+=("$f")
  done < <(find "$IOS/Lien" -name '*.swift' | sort)
  files+=("$OUT/views_src/Colors.swift" "$HERE/stubs/PushAuthorizingStub.swift" "$HERE/stubs/LiveStubs.swift" "$HERE/stubs/ViewShims.swift")

  swiftc -typecheck "${COMMON[@]}" -strict-concurrency=complete "${files[@]}" > "$OUT/views.log" 2>&1
  local status=$?
  show_diagnostics "$OUT/views.log"
  if [ $status -ne 0 ]; then
    echo "View の型検査に失敗(${#files[@]} ファイル)" >&2
    return 1
  fi
  echo "views OK(${#files[@]} ファイル。上に出た warning は、この変更で増えていないか確かめる)"
}

# ---------------------------------------------------------------------------------------------
# widget: LienWidget ターゲットの型検査(issue #17 T17a)
# ---------------------------------------------------------------------------------------------

do_widget() {
  prepare_toolchain || return 1

  # project.yml の LienWidget の sources(Swift のファイルとフォルダ)を、同じ相対パスで作業ディレクトリへ集める。
  # アセットカタログ(.xcassets)は型検査に要らない
  local dir="$OUT/widget_src"
  rm -rf "$dir"
  mkdir -p "$dir"
  python3 - "$IOS" "$dir" <<'PY' || return 1
import io, os, re, shutil, sys
ios, dest = sys.argv[1], sys.argv[2]
yml = io.open(os.path.join(ios, "project.yml"), encoding="utf-8").read()
start = yml.index("\n  LienWidget:\n")
rest = yml[start + 1:]
end = re.search(r"\n  [A-Za-z][A-Za-z0-9]*:\n", rest[1:])
block = rest[: end.start() + 1] if end else rest
paths = [m.group(1).strip() for m in re.finditer(r"^\s*- path: (.+)$", block, re.M)]
count = 0
for rel in paths:
    if rel.endswith(".xcassets"):
        continue
    src = os.path.join(ios, rel)
    if os.path.isdir(src):
        for root, _, files in os.walk(src):
            for f in files:
                if f.endswith(".swift"):
                    target = os.path.join(dest, os.path.relpath(os.path.join(root, f), ios))
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copyfile(os.path.join(root, f), target)
                    count += 1
    elif rel.endswith(".swift"):
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(src, target)
        count += 1
print("LienWidget の Swift ファイル: %d" % count)
PY

  # accessory 系(ロック画面)は macOS の SDK に無い。型検査のコピーでだけ、macOS にあるファミリーへ読み替える
  # (ファミリーの名前を使う箇所だけで、API の使い方の検査には影響しない)
  local f
  for f in "$dir"/LienWidget/*.swift; do
    sed -i '' -e 's/\.accessoryCircular/.systemLarge/g' -e 's/\.accessoryInline/.systemExtraLarge/g' -e 's/\.accessoryRectangular/.systemExtraLarge/g' "$f"
  done

  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name '*.swift' | sort)
  swiftc -typecheck -parse-as-library "${COMMON[@]}" -strict-concurrency=complete "${files[@]}" > "$OUT/widget.log" 2>&1
  local status=$?
  show_diagnostics "$OUT/widget.log"
  if [ $status -ne 0 ]; then
    echo "LienWidget の型検査に失敗(${#files[@]} ファイル)" >&2
    return 1
  fi
  echo "widget OK(${#files[@]} ファイル。ロック画面のファミリーは読み替えた型検査。上に出た warning は、この変更で増えていないか確かめる)"
}

# ---------------------------------------------------------------------------------------------

cmd="${1:-all}"
[ $# -gt 0 ] && shift
case "$cmd" in
  build) do_build ;;
  test) do_test "$@" ;;
  views) do_views ;;
  widget) do_widget ;;
  all)
    do_test && do_views && do_widget
    ;;
  -h|--help|help)
    sed -n '2,15p' "$0"
    ;;
  *)
    echo "使い方: check.sh [all|build|test [名前...]|views|widget]" >&2
    exit 1
    ;;
esac
