// PaywallView.swift — ペイウォールの画面(T33 / REQUIREMENTS §3.14)
//
// 3文脈(節目・アルバム30日超・チケット切れ)で見出しと説明だけを変える。価格・トライアルは
// PaywallViewModel が offerings から取ったものを出す(コードに書かない)。
// 押し売りしない: 閉じる(「あとで」)と「購入を復元する」を常に置き、失敗しても画面を閉じない。
// 相手がすでにプレミアムなら「適用済み」を出して購入ボタンを出さない(誤課金防止)。
//
// 文言は Strings.Paywall、色・余白は DesignSystem の定数に集約(DESIGN §3.8)。

import SwiftUI

@MainActor
struct PaywallView: View {
    @Bindable var model: PaywallViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LienSpacing.l) {
                closeRow
                header
                if model.isAppliedByPartner {
                    appliedByPartnerNote
                } else {
                    packageSection
                    purchaseSection
                }
                restoreSection
                legalSection
            }
            .padding(LienSpacing.l)
        }
        .lienPaperBackground()
        .task { await model.load() }
    }

    // MARK: - 閉じる

    private var closeRow: some View {
        HStack {
            Text(Strings.Paywall.title)
                .font(.lien(.headline))
                .foregroundStyle(LienColors.inkSecondary)
            Spacer()
            Button(Strings.Paywall.closeButton) { dismiss() }
                .accessibilityIdentifier("paywall.close")
        }
    }

    // MARK: - 見出し(文脈ごと)

    private var header: some View {
        VStack(alignment: .leading, spacing: LienSpacing.s) {
            Text(model.headline)
                .font(.lien(.title2, bold: true))
                .foregroundStyle(LienColors.ink)
                .accessibilityIdentifier("paywall.headline")
            Text(model.message)
                .font(.lien(.subheadline))
                .foregroundStyle(LienColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let trialNote = model.trialNote {
                Text(trialNote)
                    .font(.lien(.footnote, bold: true))
                    .foregroundStyle(LienColors.shareAccent)
            }
            VStack(alignment: .leading, spacing: LienSpacing.xs) {
                Text(Strings.Paywall.benefitsTitle)
                    .font(.lien(.footnote, bold: true))
                ForEach(Strings.Paywall.benefits, id: \.self) { benefit in
                    Label {
                        Text(benefit)
                            .foregroundStyle(LienColors.inkSecondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LienColors.accent)
                    }
                    .font(.lien(.footnote))
                }
            }
            .padding(.top, LienSpacing.xs)
        }
    }

    // MARK: - プラン

    private var packageSection: some View {
        VStack(spacing: LienSpacing.s) {
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(model.displayPackages) { package in
                    packageCard(package)
                }
            }
        }
    }

    private func packageCard(_ package: PaywallPackage) -> some View {
        let selected = model.selectedPackageID == package.id
        return Button {
            model.selectedPackageID = package.id
        } label: {
            HStack(alignment: .top, spacing: LienSpacing.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? LienColors.accent : LienColors.pending)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LienSpacing.xs) {
                        Text(model.priceCaption(for: package))
                            .font(.lien(.body, bold: true))
                        if package.isRecommended {
                            Text(Strings.Paywall.recommended)
                                .font(.lien(.caption2, bold: true))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(LienColors.shareGlow.opacity(0.7))
                                )
                        }
                    }
                    if let days = package.trialDays, days > 0 {
                        Text(Strings.Paywall.trialNote(days))
                            .font(.lien(.caption))
                            .foregroundStyle(LienColors.inkSecondary)
                    }
                }
                Spacer()
            }
            .padding(LienSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LienRadius.card, style: .continuous)
                    .fill(selected ? LienColors.accentSoft : LienColors.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LienRadius.card, style: .continuous)
                    .strokeBorder(selected ? LienColors.accent : LienColors.cardBorder, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
        .accessibilityIdentifier("paywall.package.\(package.kind.rawValue)")
    }

    // MARK: - 購入

    private var purchaseSection: some View {
        VStack(spacing: LienSpacing.s) {
            Button {
                Task { await model.purchase() }
            } label: {
                HStack {
                    if model.isPurchasing { ProgressView().tint(LienColors.accent) }
                    Text(model.purchaseButtonTitle)
                }
            }
            .buttonStyle(.lienPrimary)
            .disabled(!model.canPurchase)
            .accessibilityIdentifier("paywall.purchase")

            if let notice = model.noticeMessage {
                Text(notice)
                    .font(.lien(.footnote))
                    .foregroundStyle(LienColors.shareAccent)
                    .accessibilityIdentifier("paywall.notice")
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.lien(.footnote))
                    .foregroundStyle(LienColors.gentleAlert)
                    .accessibilityIdentifier("paywall.error")
            }
        }
    }

    // MARK: - 復元・規約

    private var restoreSection: some View {
        VStack(spacing: LienSpacing.s) {
            Button {
                Task { await model.restore() }
            } label: {
                if model.isRestoring {
                    ProgressView()
                } else {
                    Text(model.restoreButtonTitle)
                }
            }
            .buttonStyle(LienSecondaryButtonStyle(fillsWidth: false))
            .disabled(model.isRestoring || model.isPurchasing)
            .accessibilityIdentifier("paywall.restore")

            if model.isAppliedByPartner {
                Text(Strings.Paywall.appliedByPartner)
                    .font(.lien(.footnote))
                    .foregroundStyle(LienColors.inkSecondary)
                    .accessibilityIdentifier("paywall.appliedByPartner")
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: LienSpacing.xs) {
            Text(Strings.Paywall.legalNote)
                .font(.lien(.caption2))
                .foregroundStyle(LienColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: LienSpacing.m) {
                Link(Strings.Paywall.terms, destination: SupportLinks.termsURL)
                Link(Strings.Paywall.privacy, destination: SupportLinks.privacyURL)
            }
            .font(.lien(.caption2))
        }
    }

    private var appliedByPartnerNote: some View {
        VStack(alignment: .leading, spacing: LienSpacing.s) {
            Text(Strings.Paywall.appliedByPartner)
                .font(.lien(.subheadline))
                .foregroundStyle(LienColors.shareAccent)
                .accessibilityIdentifier("paywall.appliedByPartner")
            Text(Strings.Paywall.title)
                .font(.lien(.footnote))
                .foregroundStyle(LienColors.inkSecondary)
        }
    }
}

#if DEBUG
#Preview("チケット切れ") {
    let entitlements = EntitlementStore()
    let client = MockPurchasesClient()
    PaywallView(
        model: PaywallViewModel(
            context: .ticketEmpty,
            client: client,
            entitlements: entitlements
        )
    )
}

#Preview("相手がプレミアム") {
    let entitlements = EntitlementStore(pairPlan: .premium)
    PaywallView(
        model: PaywallViewModel(
            context: .albumLimit,
            client: MockPurchasesClient(),
            entitlements: entitlements
        )
    )
}
#endif
