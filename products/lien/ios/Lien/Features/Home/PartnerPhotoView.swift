// PartnerPhotoView.swift — ホームの「相手の今日の写真」(PV / issue #59 / REQUIREMENTS §3.11)
//
// 状態は PartnerPhotoModel が持つ。ここは描くだけ:
//   .hidden  : 何も出さない(写真が無い日・取得に失敗した・ソロ・日付またぎ — 文言も出さない)
//   .loading : 枠だけ(進行表示)。VoiceOver には「写真を読み込んでいます」
//   .ready   : サムネ(タップで原寸を全画面)+「(名前)の今日の写真」
//
// 長押し(T23 の通報・ブロック)は PartnerPhotoModel.actions に項目が入ったときだけ付く。
// 項目の文言・動作は T23 が持つ。VoiceOver には同じ操作がアクションとして出る。

import SwiftUI

// MARK: - ホームに置くカード

@MainActor
struct PartnerPhotoArea: View {
    /// nil(Stub 構成)のときは何も置かない
    let model: PartnerPhotoModel?
    let partnerName: String?

    var body: some View {
        if let model {
            PartnerPhotoCard(model: model, partnerName: partnerName)
        }
    }
}

private enum PartnerPhotoLayout {
    /// カードの最大の大きさ(サムネは長辺 512px 以下なので、これ以上に広げてもぼやけるだけ)
    static let maxWidth: CGFloat = 260
    static let maxHeight: CGFloat = 300
    /// 読み込み中の枠の高さ(横長の写真が多いので 4:3 に近い大きさ)
    static let placeholderHeight: CGFloat = 180
    static let cornerRadius: CGFloat = 16
}

@MainActor
private struct PartnerPhotoCard: View {
    let model: PartnerPhotoModel
    let partnerName: String?

    private var displayName: String {
        partnerName ?? Strings.Home.partnerFallbackLabel
    }

    var body: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: PartnerPhotoLayout.placeholderHeight)
                .frame(maxWidth: PartnerPhotoLayout.maxWidth)
                .background(
                    RoundedRectangle(cornerRadius: PartnerPhotoLayout.cornerRadius)
                        .fill(LienColors.chipBackground)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Strings.PartnerPhoto.loadingLabel)
        case .ready(let photo):
            ready(photo)
        }
    }

    @ViewBuilder
    private func ready(_ photo: PartnerPhotoThumbnail) -> some View {
        let caption = Strings.PartnerPhoto.caption(displayName)
        VStack(spacing: LienSpacing.xs) {
            Button {
                model.openViewer()
            } label: {
                Image(decorative: photo.image.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: PartnerPhotoLayout.maxWidth, maxHeight: PartnerPhotoLayout.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: PartnerPhotoLayout.cornerRadius))
            }
            .buttonStyle(.plain)
            .modifier(PartnerPhotoActionsModifier(actions: model.actions, reference: photo.reference))
            .accessibilityLabel(caption)
            .accessibilityHint(Strings.PartnerPhoto.openHint)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 長押しのメニュー(と VoiceOver のアクション)。項目が空なら何も付けない — T23 の取り付け口
private struct PartnerPhotoActionsModifier: ViewModifier {
    let actions: [PartnerPhotoAction]
    let reference: PartnerPhotoReference

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content
                .contextMenu {
                    ForEach(actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            action.perform(reference)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
                // 長押しのメニューは VoiceOver から開きにくいので、同じ操作をアクションとしても出す
                .accessibilityActions {
                    ForEach(actions) { action in
                        Button(action.title) {
                            action.perform(reference)
                        }
                    }
                }
        }
    }
}

// MARK: - 全画面(タップで開く)

/// 全画面の提示役。HomeView の背景に置く(`@Bindable` で model.isViewerPresented にひもづける)
@MainActor
struct PartnerPhotoViewerHost: View {
    @Bindable var model: PartnerPhotoModel
    let partnerName: String?

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: $model.isViewerPresented) {
                PartnerPhotoViewer(model: model, partnerName: partnerName)
            }
    }
}

/// 原寸の写真を全画面で見る。原寸が届くまではサムネを大きく出し、届いたら差し替える
/// (取れなかったときもサムネのまま — 文言は出さない)。背景のタップか閉じるボタンで閉じる
@MainActor
struct PartnerPhotoViewer: View {
    let model: PartnerPhotoModel
    let partnerName: String?

    private var displayName: String {
        partnerName ?? Strings.Home.partnerFallbackLabel
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LienColors.photoBackdrop
                .ignoresSafeArea()
                .onTapGesture { model.closeViewer() }

            if case .open(let thumbnail, let original) = model.viewer {
                let image = original ?? thumbnail
                Image(
                    image.cgImage,
                    scale: 1,
                    orientation: .up,
                    label: Text(Strings.PartnerPhoto.viewerLabel(displayName))
                )
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { model.closeViewer() }

                if original == nil {
                    ProgressView()
                        .tint(LienColors.photoControl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }

            Button {
                model.closeViewer()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LienColors.photoControl)
                    .padding(LienSpacing.m)
            }
            .accessibilityLabel(Strings.PartnerPhoto.viewerCloseButton)
        }
    }
}
