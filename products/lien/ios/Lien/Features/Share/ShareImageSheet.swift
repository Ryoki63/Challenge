// ShareImageSheet.swift — シェア画像のプレビューと共有(T22 / REQUIREMENTS §3.13)
//
// ホームの「シェア画像をつくる」と、節目(7/30/100/365日)のお祝いの両方から開く。
//   - 縦(ストーリーズ 9:16)と正方形(1:1)を切り替えて、その場でプレビューする
//   - ShareLink で PNG を共有する(写真は含まない — privacy-policy §3)
//   - 節目のときは、上に「🎉 ふたりで30日!」を出す。シートが前面に出た時点で「見た」と記録する
//
// 画像の生成は ShareImageRenderer(ImageRenderer)。生成した画像は @State に持つ(内容が変わったら作り直す)。

import SwiftUI

@MainActor
struct ShareImageSheet: View {
    let model: ShareImageModel
    let presentation: ShareImageModel.Presentation

    @Environment(\.dismiss) private var dismiss
    @State private var format: ShareImageFormat = .story
    @State private var images: [ShareImageFormat: ShareRenderedImage] = [:]
    @State private var renderFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(Strings.Share.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Share.closeButton) { dismiss() }
                }
            }
        }
        .tint(LienColors.shareAccent)
        .presentationDetents([.large])
        .task { await model.load() }
        .task(id: model.content) { renderImages() }
        .onAppear { model.presentationDidAppear() }
        .onDisappear { model.dismissPresentation() }
    }

    // MARK: 見出し

    @ViewBuilder
    private var header: some View {
        if let milestone = presentation.milestone {
            VStack(spacing: 6) {
                Text(Strings.Share.milestoneTitle(milestone.days))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(Strings.Share.milestoneBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 6) {
                Text(Strings.Share.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(Strings.Share.loading)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)

        case .unavailable:
            Text(Strings.Share.unavailableMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)

        case .failed:
            VStack(spacing: 12) {
                Text(Strings.Share.errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(Strings.Share.retry) {
                    Task { await model.load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 240)

        case .ready:
            if let content = model.content {
                readyContent(content)
            }
        }
    }

    private func readyContent(_ content: ShareImageContent) -> some View {
        VStack(spacing: 14) {
            if let rendered = images[format] {
                Image(decorative: rendered.image, scale: ShareImageFormat.scale)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: format == .story ? 380 : 300)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text(Strings.Share.previewLabel(content.myName, content.partnerName, content.streakDays))
                    )
            } else if renderFailed {
                VStack(spacing: 10) {
                    Text(Strings.Share.errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(Strings.Share.retry) { renderImages() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

            Picker(Strings.Share.formatPickerLabel, selection: $format) {
                Text(Strings.Share.formatStory).tag(ShareImageFormat.story)
                Text(Strings.Share.formatSquare).tag(ShareImageFormat.square)
            }
            .pickerStyle(.segmented)

            if let rendered = images[format] {
                ShareLink(
                    item: ShareImagePayload(data: rendered.data, filename: rendered.filename),
                    preview: SharePreview(
                        Strings.Share.sharePreviewTitle(content.streakDays),
                        image: Image(decorative: rendered.image, scale: ShareImageFormat.scale)
                    )
                ) {
                    Label(Strings.Share.shareButton, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(Strings.Share.privacyNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: 画像の生成

    private func renderImages() {
        guard let content = model.content else { return }
        renderFailed = false
        var rendered: [ShareImageFormat: ShareRenderedImage] = [:]
        for format in ShareImageFormat.allCases {
            guard let image = ShareImageRenderer.render(content, format: format),
                  let data = ShareImageRenderer.pngData(image) else {
                renderFailed = true
                continue
            }
            rendered[format] = ShareRenderedImage(
                image: image,
                data: data,
                filename: "lien-\(String(format: "%03d", content.streakDays))-\(format.rawValue).png"
            )
        }
        images = rendered
    }
}
