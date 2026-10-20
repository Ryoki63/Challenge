// TicketBalanceView.swift — ホームのお休みチケット残数バッジ(REQUIREMENTS §3.6 / DESIGN §3.4 / T19a #19)
//
// - ペア共有の在庫(snapshot の ticketBalance)を、そのまま「残り○枚」で出す(受信者視点で反転しない)
// - **0枚でも出す**: 0 は「まだ守ってもらえる」ではなく「いまは無い」だが、罰なしの原則(§3.5)で
//   バッジを消さない・責める言い方にしない。次に月次付与(invite-accept / grant-tickets)で増える
// - nil(キーが無い古いサーバー・ソロ・残数を読めていない)のときは、呼び出し側(HomeView)がバッジごと出さない
// - お休み宣言 UI は 1.0.1(D3)。このファイルは v1.0 の残数表示だけを持つ

import SwiftUI

/// ホームのチケット残数バッジ。0 以上を渡す(表示条件は HomeViewModel.ticketBalance)
@MainActor
struct TicketBalanceBadge: View {
    let balance: Int
    /// 0枚のときだけ、タップでペイウォール(T33 / REQUIREMENTS §3.14)を開く。
    /// nil(0枚より多い・導線を出さない組み立て)なら、ただのバッジ
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
            // タップで何が起きるかを VoiceOver でも分かるようにする(押し売りしない。閉じるボタンはペイウォール側にある)
            .accessibilityHint(Strings.Paywall.ticketEmptyHeadline)
        } else {
            content
        }
    }

    private var content: some View {
        Label(Strings.Tickets.balance(balance), systemImage: "ticket.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, LienSpacing.s)
            .padding(.vertical, LienSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LienColors.chipBackground)
            )
            // アイコンと文字を別々に読ませず、「お休みチケット 残り2枚」と1つで読み上げる
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.Tickets.balance(balance))
    }
}

#if DEBUG
#Preview("残り2枚") {
    TicketBalanceBadge(balance: 2)
        .padding()
}

#Preview("残り0枚(罰なしで表示する)") {
    TicketBalanceBadge(balance: 0)
        .padding()
}
#endif
