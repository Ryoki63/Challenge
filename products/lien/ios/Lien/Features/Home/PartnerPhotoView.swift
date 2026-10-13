// PartnerPhotoView.swift — ホームの「相手の今日の写真」(PV / issue #59 / REQUIREMENTS §3.11)
//
// 状態は PartnerPhotoModel が持つ。ここは描くだけ:
//   .hidden  : 何も出さない(写真が無い日・取得に失敗した・ソロ・日付またぎ — 文言も出さない)
//   .loading : 枠だけ(進行表示)。VoiceOver には「写真を読み込んでいます」
//   .ready   : サムネ(タップで原寸を全画面)+「(名前)の今日の写真」。写真と同じ大きさの枠に、角丸の切り抜きとタップ範囲を合わせる
//              (PartnerPhotoCardLayout.fittedSize — 縦長の写真で外枠だけが広がり、角が四角く残るのを避ける)
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

/// カードのサムネ。写真の縦横比から大きさを計算で決め(PartnerPhotoCardLayout.fittedSize)、その大きさの枠で
/// 角丸に切り抜く。`.frame(maxWidth:maxHeight:)` の後に切り抜くと、縦長の写真では外枠(幅いっぱい)が切り抜かれて
/// 写真の角が四角く残り、左右の透明な余白までタップ範囲に入る
struct PartnerPhotoThumbnailImage: View {
    let image: PartnerPhotoImage

    var body: some View {
        let size = PartnerPhotoCardLayout.fittedSize(aspectRatio: image.aspectRatio)
        let shape = RoundedRectangle(cornerRadius: PartnerPhotoCardLayout.cornerRadius)
        Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape) // タップ範囲も、角丸の写真そのもの
    }
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
                .frame(maxWidth: .infinity, minHeight: PartnerPhotoCardLayout.placeholderHeight)
                .frame(maxWidth: PartnerPhotoCardLayout.maxWidth)
                .background(
                    RoundedRectangle(cornerRadius: PartnerPhotoCardLayout.cornerRadius)
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
                PartnerPhotoThumbnailImage(image: photo.image)
            }
            .buttonStyle(.plain)
            .modifier(PartnerPhotoActionsModifier(actions: model.actions) { action in
                action.perform(photo.reference)
            })
            .accessibilityLabel(caption)
            .accessibilityHint(Strings.PartnerPhoto.openHint)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 長押しのメニュー(と VoiceOver のアクション)。項目が空なら何も付けない — T23 の取り付け口。
/// `perform` が項目を実行する(カードはそのまま実行、全画面は閉じてから実行)
private struct PartnerPhotoActionsModifier: ViewModifier {
    let actions: [PartnerPhotoAction]
    let perform: (PartnerPhotoAction) -> Void

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content
                .contextMenu {
                    ForEach(actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
                // 長押しのメニューは VoiceOver から開きにくいので、同じ操作をアクションとしても出す
                .accessibilityActions {
                    ForEach(actions) { action in
                        Button(action.title) {
                            perform(action)
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
            // 全画面の通報・ブロックは、閉じ終わってから(onDismiss)ホームの確認を出す(model.closeViewer(then:))
            .fullScreenCover(isPresented: $model.isViewerPresented, onDismiss: { model.viewerDidDismiss() }) {
                PartnerPhotoViewer(model: model, partnerName: partnerName)
            }
    }
}

/// 原寸の写真を全画面で見る。原寸が届くまではサムネを大きく出し(スピナー付き)、届いたら差し替える
/// (取れなかったときは、スピナーを止めてサムネのまま — 文言は出さない)。背景のタップか閉じるボタンで閉じる。
/// 通報・ブロック(T23 #23)は、左上の「…」メニューと写真の長押し、VoiceOver のアクション。選ぶと全画面を閉じてから、
/// ホームに確認を出す(拡大したままでも通報できる — App Store ガイドライン 1.2)
@MainActor
struct PartnerPhotoViewer: View {
    let model: PartnerPhotoModel
    let partnerName: String?

    private var displayName: String {
        partnerName ?? Strings.Home.partnerFallbackLabel
    }

    /// 開いている写真の指し先(通報の対象)。カードの写真が無くなっていれば nil
    private var reference: PartnerPhotoReference? {
        if case .ready(let photo) = model.state { return photo.reference }
        return nil
    }

    /// 項目を実行する: 全画面を閉じ、閉じ終わってから実行する
    private func perform(_ action: PartnerPhotoAction) {
        guard let reference else { return }
        model.closeViewer { action.perform(reference) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LienColors.photoBackdrop
                .ignoresSafeArea()
                .onTapGesture { model.closeViewer() }

            if let image = model.viewer.displayedImage {
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
                .modifier(PartnerPhotoActionsModifier(actions: model.actions, perform: perform))

                // 原寸を取りに行っている間だけ。取れなかったあとは止める(サムネのまま。文言は出さない)
                if model.viewer.isLoadingOriginal {
                    ProgressView()
                        .tint(LienColors.photoControl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }

            if !model.actions.isEmpty, reference != nil {
                Menu {
                    ForEach(model.actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(LienColors.photoControl)
                        .padding(LienSpacing.m)
                }
                .accessibilityLabel(Strings.PartnerPhoto.viewerMenuButton)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // VoiceOver の「2本指で Z を描く」(エスケープ)でも閉じられる
        .accessibilityAction(.escape) { model.closeViewer() }
    }
}
