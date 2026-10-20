// ShareImageModel.swift — シェア画像の状態と、画像に載せる内容(T22 / REQUIREMENTS §3.13)
//
// シェア画像に載せるのは、植物の現在の姿・2人のニックネーム・ストリーク日数・開始日・アプリ名だけ。
// **チェックイン写真は載せない**(REQUIREMENTS §3.13・privacy-policy §3)。写真はこのファイルの内容に一切入らない。
//
// - 開始日は「いまのストリークの1日目」= 今日 − (ストリーク日数 − 1)。pairs.started_on(ペア成立日)は
//   PairSnapshot の契約に無く、このタスク(T22。iOS レーン)ではサーバーの契約を変えないため、
//   いまのストリークの開始日を使う。ストリークが途切れたら、その新しいストリークの1日目になる
//   (「30日」の画像に、その30日の1日目を添える、という意味で一貫する)
// - 自分のニックネームは users 行から読む(AuthServicing.fetchProfile)。読めなかったときのために、
//   最後に読めた名前を端末の UserDefaults に控える(オフラインでも、直前に使っていた名前でつくれる)。
//   控えも無いときだけ失敗にする(2人のニックネームが無い画像はつくらない)
// - 画像の描画は ShareImageCardView / ShareImageRenderer(iOS の SwiftUI)。このファイルは Foundation だけで、
//   macOS の下見(macos-check)でもテストできる
// - 画面に出すのは ShareImageSheet。モデルは「出すか」「何を載せるか」だけを持つ

import CoreGraphics
import Foundation
import Observation

// MARK: - 画像の形

/// シェア画像の2種(REQUIREMENTS §3.13)。ストーリーズ用の縦 9:16 と、X 用の正方形 1:1
enum ShareImageFormat: String, CaseIterable, Equatable, Identifiable, Sendable {
    /// ストーリーズ用(9:16)
    case story
    /// X など用(1:1)
    case square

    var id: String { rawValue }

    /// 描くときの大きさ(ポイント)。3倍で書き出すので、1080×1920 / 1080×1080 になる
    var pointSize: CGSize {
        switch self {
        case .story: return CGSize(width: 360, height: 640)
        case .square: return CGSize(width: 360, height: 360)
        }
    }

    /// 書き出す画像の大きさ(ピクセル)
    var pixelSize: CGSize {
        CGSize(width: pointSize.width * Self.scale, height: pointSize.height * Self.scale)
    }

    /// 1ポイントあたりの画素(Retina の 3 倍。1080 幅)
    static let scale: CGFloat = 3
}

// MARK: - 画像に載せる内容

/// シェア画像に載せる内容(写真は無い)
struct ShareImageContent: Equatable, Sendable {
    let myName: String
    let partnerName: String
    let streakDays: Int
    /// このストリークの1日目
    let startedOn: Date
    /// 植物の成長段階(0〜9。知らない段階は描くときに丸める)
    let plantStage: Int
    /// 画像の隅に小さく置くアプリ名(オーガニック流入装置 — REQUIREMENTS §3.13)
    let appName: String

    /// このストリークの1日目。今日から (streakDays - 1) 日さかのぼる
    static func streakStartDate(streakDays: Int, now: Date, calendar: Calendar) -> Date {
        let offset = max(streakDays, 1) - 1
        return calendar.date(byAdding: .day, value: -offset, to: now) ?? now
    }

    /// 「2026年9月21日」の形。時刻は Asia/Tokyo で見る(共通ポリシー8)
    static func dateText(_ date: Date, calendar: Calendar? = nil) -> String {
        let calendar = calendar ?? ShareImageModel.defaultCalendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    var startedOnText: String {
        Self.dateText(startedOn)
    }
}

// MARK: - モデル

@MainActor
@Observable
final class ShareImageModel {
    /// 画面に出すもの(同時に1つ)
    enum Presentation: Equatable, Identifiable {
        /// ホームの「シェア画像をつくる」から
        case manual
        /// 節目のお祝いから
        case milestone(ShareMilestone)

        var id: String {
            switch self {
            case .manual: return "manual"
            case .milestone(let milestone): return "milestone:\(milestone.id)"
            }
        }

        var milestone: ShareMilestone? {
            if case .milestone(let milestone) = self { return milestone }
            return nil
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        /// まだシェアできる記録が無い(ソロ・ストリーク 0)
        case unavailable
        case failed
    }

    /// 自分のニックネームを読む口(本実装は AuthServicing.fetchProfile。テストは差し替える)
    typealias NameLoader = () async throws -> String

    /// 最後に読めた自分のニックネームの控え(端末の UserDefaults)
    static let cachedNameKey = "lien.shareImage.myName.v1"

    /// いま出している画面(nil = 出していない)
    private(set) var presentation: Presentation?
    private(set) var loadState: LoadState = .idle
    /// 画像に載せる内容(読み込みが済むまで nil)
    private(set) var content: ShareImageContent?

    @ObservationIgnored private let nameLoader: NameLoader?
    @ObservationIgnored private let memoryStore: ShareMilestoneStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var currentSnapshot: PairSnapshot?
    @ObservationIgnored private var cachedMyName: String?

    /// 端末の時刻を Asia/Tokyo の日付で見るための既定のカレンダー
    nonisolated static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }

    init(
        nameLoader: NameLoader? = nil,
        memoryStore: ShareMilestoneStoring = UserDefaultsShareMilestoneStore(),
        now: @escaping () -> Date = Date.init,
        calendar: Calendar? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.nameLoader = nameLoader
        self.memoryStore = memoryStore
        self.now = now
        self.calendar = calendar ?? Self.defaultCalendar
        self.defaults = defaults
        let cached = defaults.string(forKey: Self.cachedNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cachedMyName = (cached?.isEmpty ?? true) ? nil : cached
    }

    // MARK: ホームからの入口

    /// シェアできる記録があるか(ペア成立中・ストリーク 1日以上)
    var canShare: Bool {
        guard let snapshot = currentSnapshot else { return false }
        return snapshot.pairId != nil && snapshot.streakCurrent > 0
    }

    /// ホームの「シェア画像をつくる」(任意タイミング — REQUIREMENTS §3.13)
    func presentManual() {
        guard canShare else { return }
        presentation = .manual
    }

    /// シートを閉じた(節目なら「見た」と記録する。表示を取りこぼしていても、もう一度は出さない)
    func dismissPresentation() {
        if let milestone = presentation?.milestone {
            markShown(milestone)
        }
        presentation = nil
        loadState = .idle
        content = nil
    }

    /// `.sheet(item:)` の Binding から呼ばれる
    func setPresentation(_ presentation: Presentation?) {
        guard let presentation else {
            dismissPresentation()
            return
        }
        self.presentation = presentation
    }

    /// シートが前面に表示された。節目ならここで初めて「出した」と記録する
    func presentationDidAppear() {
        guard let milestone = presentation?.milestone else { return }
        markShown(milestone)
    }

    // MARK: snapshot の変化(HomeViewModel から)

    /// ホームが snapshot を読み直す・更新するたびに呼ばれる。節目に届いていれば、お祝いのシートを出す
    func snapshotDidChange(_ snapshot: PairSnapshot?) {
        currentSnapshot = snapshot
        guard let snapshot, let pairId = snapshot.pairId, snapshot.streakCurrent > 0 else {
            // ソロに戻った・記録が無い: 開いているシェア画像を閉じ、旧ペアの記録も忘れる
            // (旧ペアの名前を出したままにしない。記録は pairId だけだが、端末に残さない)
            presentation = nil
            var memory = memoryStore.load()
            let before = memory
            memory.forgetOtherPairs(keeping: nil)
            if memory != before { memoryStore.save(memory) }
            return
        }

        let streakStartDay = PlantDay.number(of: now(), calendar: calendar) - (snapshot.streakCurrent - 1)
        var memory = memoryStore.load()
        let before = memory
        let milestone = memory.observe(
            pairId: pairId,
            streakDays: snapshot.streakCurrent,
            streakStartDay: streakStartDay
        )
        if memory != before { memoryStore.save(memory) }

        // すでに何か出している(手動のシェアなど)ときは、閉じたあとの次の読み込みで改めて判定する
        if let milestone, presentation == nil {
            presentation = .milestone(milestone)
        }
    }

    // MARK: 画像の内容を読む

    /// シートを開いたときに呼ぶ。自分のニックネームを読み、画像に載せる内容を組み立てる
    func load() async {
        guard let snapshot = currentSnapshot, snapshot.pairId != nil, snapshot.streakCurrent > 0 else {
            loadState = .unavailable
            content = nil
            return
        }

        loadState = .loading
        let name: String
        do {
            name = try await myName()
        } catch {
            loadState = .failed
            content = nil
            return
        }
        // 読み込みの間にシートを閉じた・別のペアになった
        guard presentation != nil, currentSnapshot?.pairId == snapshot.pairId else { return }

        let partner = snapshot.partnerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let partnerName = (partner?.isEmpty ?? true) ? Strings.Share.partnerFallbackName : partner ?? Strings.Share.partnerFallbackName
        let startedOn = ShareImageContent.streakStartDate(
            streakDays: snapshot.streakCurrent,
            now: now(),
            calendar: calendar
        )
        content = ShareImageContent(
            myName: name,
            partnerName: partnerName,
            streakDays: snapshot.streakCurrent,
            startedOn: startedOn,
            plantStage: snapshot.plantStage,
            appName: Strings.Widget.displayName
        )
        loadState = .ready
    }

    /// サインアウト・アカウント削除のあと(前のアカウントの名前・節目の記録を持ち越さない)
    func reset() {
        presentation = nil
        loadState = .idle
        content = nil
        currentSnapshot = nil
        cachedMyName = nil
        defaults.removeObject(forKey: Self.cachedNameKey)
        memoryStore.reset()
    }

    // MARK: 自分のニックネーム

    private func myName() async throws -> String {
        guard let nameLoader else {
            // プレビュー・テストで読み込み口が無いときは、控えか「あなた」でつくる
            return cachedMyName ?? Strings.Share.meFallbackName
        }
        do {
            let name = try await nameLoader().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ShareImageError.emptyName }
            cachedMyName = name
            defaults.set(name, forKey: Self.cachedNameKey)
            return name
        } catch {
            // オフラインでも、直前に読めていた名前でつくる
            if let cachedMyName { return cachedMyName }
            throw error
        }
    }

    private func markShown(_ milestone: ShareMilestone) {
        var memory = memoryStore.load()
        memory.markShown(milestone)
        memoryStore.save(memory)
    }
}

enum ShareImageError: Error, Equatable {
    /// users.nickname が空(オンボーディング前など)
    case emptyName
}
