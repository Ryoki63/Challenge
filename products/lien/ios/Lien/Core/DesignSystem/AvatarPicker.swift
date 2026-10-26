// AvatarPicker.swift — プロフィールのアイコンを、タネの子のイラスト12種から選ぶ(LienAvatar)
//
// オンボーディングとプロフィール編集(設定の Form の行の中)で同じものを使う。4列 × 3行。
// 選んだ絵は、輪(アクセント色・3pt・絵とのすき間 2pt)と右下のチェックと、わずかな拡大で示す
// (色だけに頼らないので、色の見分けにくい人にも伝わる。読み上げには「選択中」が付く)。
// 1つ分は正方形(絵 + すき間 + 輪)で、広い画面では 70pt(絵そのものは 60pt)で止めて中央に寄せる。
// 幅 320pt の画面の Form の行(中身は 256pt ほど)では、列の幅に合わせて縮む(絵は 51pt ほど)。
// 文言はここに持たない(読み上げの名前は LienAvatar.displayName。見出しは置き場所の画面が付ける)。

import SwiftUI

struct AvatarPicker: View {
    @Binding var selection: LienAvatar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 寸法(pt)
    private static let columnCount = 4
    private static let maxCellSide: CGFloat = 70
    private static let cellSpacing = LienSpacing.xs
    private static let maxGridWidth: CGFloat = maxCellSide * CGFloat(columnCount) + cellSpacing * CGFloat(columnCount - 1)
    private static let ringWidth: CGFloat = 3
    private static let ringGap: CGFloat = 2
    private static let badgeSize: CGFloat = 20
    private static let selectedScale: CGFloat = 1.06

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.cellSpacing), count: Self.columnCount)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
            ForEach(LienAvatar.allCases) { avatar in
                cell(for: avatar)
            }
        }
        // 広い画面では 4列ぶんの幅で止め、余ったぶんは左右に振り分ける(縦と横のすき間をそろえるため)
        .frame(maxWidth: Self.maxGridWidth)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func cell(for avatar: LienAvatar) -> some View {
        let isSelected = avatar == selection
        return Button {
            selection = avatar
        } label: {
            Image(avatar.assetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                // 輪が付いても絵の大きさが変わらないよう、選んでいない絵も輪のぶん内側に置く
                .padding(Self.ringWidth + Self.ringGap)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(LienColors.accent, lineWidth: Self.ringWidth)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected { checkBadge }
                }
                .scaleEffect(isSelected ? Self.selectedScale : 1)
                .contentShape(Circle())
        }
        // Form の行の中では、plain にしないと行全体が1つのボタンのように反応する
        .buttonStyle(.plain)
        .accessibilityLabel(avatar.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
    }

    /// 右下のチェック。絵の上でも輪郭が立つよう、背景色の縁を付ける
    /// (チェックの色も背景色にするので、ライトでは白、ダークでは黒がアクセント色の上に乗って読める)
    private var checkBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: Self.badgeSize))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.background, LienColors.accent)
            .background(Circle().fill(.background).padding(-2))
            .transition(.scale.combined(with: .opacity))
            .accessibilityHidden(true)
    }
}

// MARK: - プレビュー

private struct AvatarPickerPreview: View {
    @State private var selection: LienAvatar = .defaultAvatar

    var body: some View {
        AvatarPicker(selection: $selection)
            .padding(LienSpacing.l)
    }
}

#Preview("アイコンの選択") {
    AvatarPickerPreview()
}

#Preview("アイコンの選択(ダーク)") {
    AvatarPickerPreview()
        .preferredColorScheme(.dark)
}
