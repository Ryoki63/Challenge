// Colors.swift — DesignSystem 最小カラーパレット(T13 / DESIGN §3.8)
//
// 色は View 内に直書きせず、ここに定数として置く。
// 既存画面(Onboarding / Pairing / PromiseSetup)の色使いを踏襲した最小セット。
// 本格的なパレット整備はビジュアル確定(G2)後のタスクで行う。

import SwiftUI
import UIKit

enum LienColors {
    /// 完了状態のチェック・植物のアクセント
    static let done = Color.green
    /// 未完了状態(自分未完 = グレー — REQUIREMENTS §3.10)
    static let pending = Color.gray
    /// エラー文言(責めないトーンの暖色 — 既存画面の .orange を踏襲)
    static let gentleAlert = Color.orange
    /// 今日の状態チップの背景
    static let chipBackground = Color(uiColor: .secondarySystemBackground)
    /// 相手の写真を全画面で見るときの背景(写真の周りを暗くする)
    static let photoBackdrop = Color.black
    /// 全画面の写真に重ねる操作(閉じるボタン・読み込み中の表示)の色
    static let photoControl = Color.white
    /// 植物の全画面の演出(段階アップ・おかえり — PB #57)の背景。ライト / ダークの標準の背景(プレートが暗い背景でも輪郭を見せる)
    static let celebrationBackground = Color(uiColor: .systemBackground)
    /// カレンダー履歴の達成の点(T18)。無彩色の中立表現にする(REVIEW-2026-10-12 §4.2)
    static let historyMark = Color.primary
}
