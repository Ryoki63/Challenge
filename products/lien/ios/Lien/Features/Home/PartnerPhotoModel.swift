// PartnerPhotoModel.swift — ホームの「相手の今日の写真」の状態(PV / issue #59 / REQUIREMENTS §3.11)
//
// 出すもの: 相手が今日添えた写真のサムネ(タップで原寸を全画面)。出さないとき(= 何も出さない):
//   - snapshot.hasPartnerPhotoToday が false(取りに行かない)
//   - ソロ・ペア解消後(pairId が null)。持っている写真も捨てる
//   - 相手の行に photo_path が無い・規約に合わない
//   - 取得に失敗した・署名付き URL が弾かれた(RLS・失効・通信)。文言は出さず、植物だけに戻る(罰なし・§3.5)
//   - 日付が変わった(出すのは「今日の写真」だけ。過去の写真を見返す画面はアルバム = v1.1)
//
// 持つのはメモリ上のサムネ1枚(と、開いている間だけの原寸)。署名付き URL も画像も、App Group にも
// ディスクにも書かない(ウィジェットへは渡さない — M ウィジェットの写真は v1.0.1)。
//
// キャッシュ: 同じ日・同じペアの写真は、`revalidateInterval` の間は取り直さない
// (同じパスへの差し替え — 相手が同じ日に写真を貼り直した — を拾うため、それを過ぎたら次の機会に取り直す)。
// 取得は同じ写真について同時に1本だけ。日付またぎ・ペア解消・別の取得への置き換えで、古い取得の結果は捨てる。
//
// HomeViewModel.load / apply が snapshotDidChange を呼ぶ(同期的に状態を決め、通信だけを Task で走らせる)。
// テストは update(with:) を await する。

import Foundation
import Observation

@MainActor
@Observable
final class PartnerPhotoModel {
    /// ホームのカードの状態
    enum State: Equatable {
        /// 何も出さない
        case hidden
        /// 取りに行っている(枠だけ出す)
        case loading
        /// サムネを出す
        case ready(PartnerPhotoThumbnail)
    }

    /// タップで開く全画面の状態
    enum Viewer: Equatable {
        case closed
        /// original が nil の間はサムネを大きく出して、取れたら差し替える。取れなければ(失敗しても)サムネのまま
        case open(thumbnail: PartnerPhotoImage, original: PartnerPhotoImage?)
    }

    /// 同じ日の写真を取り直すまでの間隔(秒)。この間はキャッシュをそのまま出し、通信しない
    static let revalidateInterval: TimeInterval = 15 * 60

    private(set) var state: State = .hidden
    private(set) var viewer: Viewer = .closed

    /// 写真の長押しメニューの項目(T23 が通報・ブロックを入れる)。空なら長押しは何も起きない
    let actions: [PartnerPhotoAction]

    // MARK: 依存

    @ObservationIgnored private let provider: PartnerPhotoProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// 日付またぎの見張りが待つ(テストは差し替える)。取り消されたら早く戻る
    @ObservationIgnored private let sleep: (TimeInterval) async -> Void

    // MARK: 内部状態(メモリだけ)

    private struct Key: Equatable {
        let pairID: String
        let dateLocal: String
    }

    private struct CacheEntry {
        let key: Key
        let thumbnail: PartnerPhotoThumbnail
        let loadedAt: Date
    }

    @ObservationIgnored private var cache: CacheEntry?
    /// 取得中の写真(同じ写真の二重取得を避ける)
    @ObservationIgnored private var inFlight: Key?
    /// 取得の世代。置き換え・消去のたびに進め、古い取得の結果が新しい状態を上書きしないようにする
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var latestSnapshot: PairSnapshot?
    /// 走っている取得(テストが完了を待つのに使う)
    @ObservationIgnored private(set) var fetchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var viewerTask: Task<Void, Never>?

    init(
        provider: PartnerPhotoProviding,
        actions: [PartnerPhotoAction] = [],
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.provider = provider
        self.actions = actions
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    // MARK: 入口

    /// snapshot が変わった(HomeViewModel.load / apply)。状態は同期的に決め、通信だけを Task で走らせる
    func snapshotDidChange(_ snapshot: PairSnapshot?) {
        latestSnapshot = snapshot
        guard let request = reconcile() else { return }
        fetchTask = Task { [weak self] in
            await self?.performFetch(request)
        }
    }

    /// `snapshotDidChange` と同じことをして、取得の完了まで待つ(テスト用)
    func update(with snapshot: PairSnapshot?) async {
        latestSnapshot = snapshot
        guard let request = reconcile() else { return }
        await performFetch(request)
    }

    /// 前面に出したまま日付が変わったら写真を消す(View の .task から呼ぶ。View が消えるとキャンセルされる)。
    /// 0:00 の1秒後に、最後に見た snapshot で状態を決め直す(昨日の snapshot は「今日のもの」ではないので隠れる)
    func watchDayChanges() async {
        while !Task.isCancelled {
            let current = now()
            let midnight = DayBoundary.nextMidnight(after: current, calendar: calendar)
            let seconds = max(1, midnight.timeIntervalSince(current)) + 1
            await sleep(seconds)
            if Task.isCancelled { return }
            snapshotDidChange(latestSnapshot)
        }
    }

    // MARK: 全画面

    /// カードのタップ。サムネを大きく出して、原寸を取りに行く(取れたら差し替える)
    func openViewer() {
        guard case .ready(let photo) = state else { return }
        viewerTask?.cancel()
        viewer = .open(thumbnail: photo.image, original: nil)
        let reference = photo.reference
        viewerTask = Task { [weak self] in
            await self?.loadOriginal(for: reference)
        }
    }

    /// 全画面を閉じる。原寸はここで手放す(メモリに残さない)
    func closeViewer() {
        viewerTask?.cancel()
        viewerTask = nil
        if viewer != .closed { viewer = .closed }
    }

    var isViewerOpen: Bool {
        if case .open = viewer { return true }
        return false
    }

    /// 全画面の提示の入口(`.fullScreenCover(isPresented: $model.isViewerPresented)` 用)。
    /// 開くのは openViewer だけ。ここへ false を書くと(下へスワイプなどで)閉じる
    var isViewerPresented: Bool {
        get { isViewerOpen }
        set { if !newValue { closeViewer() } }
    }

    // MARK: private — 状態の決定(同期)

    private struct FetchRequest {
        let key: Key
        let generation: Int
    }

    /// 今の snapshot と時刻から、表示の状態を決める。通信が要るときだけ取得の依頼を返す
    private func reconcile() -> FetchRequest? {
        // ソロ・ペア解消後・snapshot なし: 何も持たない
        guard let snapshot = latestSnapshot, let pairID = snapshot.pairId else {
            hide()
            return nil
        }
        let pair = pairID.lowercased()
        let current = now()
        let today = DayBoundary.dateLocalString(for: current, calendar: calendar)

        // ペアが変わった・日付が変わった: 古い写真は捨てる
        if let entry = cache, entry.key.pairID != pair || entry.key.dateLocal != today {
            dropCache()
        }
        if let key = inFlight, key.pairID != pair || key.dateLocal != today {
            cancelFetch()
        }

        // 写真が無い日は何も出さない。snapshot が昨日のものなら hasPartnerPhotoToday は昨日の値かもしれないので、
        // 同期で今日の値に変わるまで出さない(朝いちばんに枠だけ出てすぐ消える、をなくす)
        let isFromToday = DayBoundary.dateLocalString(for: snapshot.updatedAt, calendar: calendar) == today
        guard snapshot.hasPartnerPhotoToday, isFromToday else {
            hide()
            return nil
        }

        let key = Key(pairID: pair, dateLocal: today)
        if let entry = cache, current.timeIntervalSince(entry.loadedAt) < Self.revalidateInterval {
            state = .ready(entry.thumbnail)
            return nil
        }
        if inFlight == key { return nil }

        // 取りに行く。古い写真(再確認)があれば、取れるまでそのまま出しておく
        generation += 1
        inFlight = key
        if let entry = cache {
            state = .ready(entry.thumbnail)
        } else {
            state = .loading
        }
        return FetchRequest(key: key, generation: generation)
    }

    // MARK: private — 取得(非同期)

    private func performFetch(_ request: FetchRequest) async {
        let outcome: Result<PartnerPhotoThumbnail?, Error>
        do {
            outcome = .success(
                try await provider.loadThumbnail(pairID: request.key.pairID, dateLocal: request.key.dateLocal)
            )
        } catch {
            outcome = .failure(error)
        }
        // 別の取得に置き換わった・消去された: この結果は捨てる
        guard generation == request.generation else { return }
        inFlight = nil

        switch outcome {
        case .success(let thumbnail?):
            cache = CacheEntry(key: request.key, thumbnail: thumbnail, loadedAt: now())
            state = .ready(thumbnail)
        case .success(nil):
            // 行が無い・photo_path が無い・規約に合わない: 出さない
            hide()
        case .failure(let error):
            // 失敗(署名付き URL が弾かれた・RLS・失効・通信)。文言は出さない。
            // 通信が切れていただけで、すでに出している今日の写真があるなら、そのまま出しておく。
            // それ以外(読めなくなった)は、持っていた写真も捨てる(ペア解消の反映より先に RLS が閉じた場合など)
            if let entry = cache, (error as? PartnerPhotoError) == .network {
                state = .ready(entry.thumbnail)
            } else {
                hide()
            }
        }
    }

    private func loadOriginal(for reference: PartnerPhotoReference) async {
        do {
            let original = try await provider.loadOriginal(of: reference)
            // 閉じられた・別の写真に替わった・取り消された結果は使わない
            guard
                !Task.isCancelled,
                case .open(let thumbnail, _) = viewer,
                case .ready(let photo) = state,
                photo.reference == reference
            else { return }
            viewer = .open(thumbnail: thumbnail, original: original)
        } catch {
            // 取れなくても何も出さない: サムネを大きく出したまま(閉じれば戻る)
        }
    }

    // MARK: private — 消去

    /// 何も出さない・何も持たない。取得中の依頼は取り消し、持っている写真も開いている全画面も捨てる
    /// (ソロ・ペア解消・写真の無い日・日付またぎ)
    private func hide() {
        cancelFetch()
        dropCache()
        // 変わらないときは書かない(同期のたびに画面を更新させない)
        if state != .hidden { state = .hidden }
    }

    private func dropCache() {
        cache = nil
        closeViewer()
        if case .ready = state { state = .hidden }
    }

    private func cancelFetch() {
        generation += 1
        inFlight = nil
        fetchTask?.cancel()
        fetchTask = nil
    }
}
