// PlantNamingModel.swift — 植物の名前を付ける・変えるフォームの状態(issue #57 / docs/GROWTH.md §5.3)
//
// 使われ方は2つで、どちらも同じ1つのモデル(HomeViewModel が持つ)を使う:
//   - 最初の「ふたば」の段階アップの演出の中(StageCelebrationView): mode = .first
//   - ホームの植物の下の「名前をつける」(まだ名前が無いとき)/ 名前の行(変えるとき)から開くシート(PlantNameSheet): .first / .rename
//
// 結果:
//   - 保存できた(.saved): 端末の snapshot の名前を直す(HomeViewModel.applyPlantName)
//   - 相手が先に付けていた(.adopted — first の 409): その名前に決まる。「名前は『みどり』になったよ」と知らせる
//     (誰が付けたかは、アプリ内には書かない — GROWTH §5.3。サーバーが返さず、再インストールで記録が消えて誤表示になるため)
//   - 失敗: 下書きは残し(やり直せる)、責めない文言を出す(§3.5)
// 入力の検査は PlantNameRules(サーバーと同じ規則)。入力中は、打ち始めてから(空でないとき)だけエラーを出す。

import Foundation
import Observation

/// 名前を付けた結果を、端末の snapshot へ反映するための知らせ(HomeViewModel.applyPlantName が受ける)
enum PlantNameApplication: Equatable, Sendable {
    /// 自分の名前が入った
    case saved(name: String)
    /// 相手が先に付けていた名前に決まった
    case adopted(name: String)
}

@MainActor
@Observable
final class PlantNamingModel {
    /// いま開いているフォームの種類
    private(set) var mode: PlantNameMode = .first
    /// 入力中の名前
    var draft = ""
    private(set) var isSaving = false
    /// 保存に失敗したときのメッセージ(責めない文言。下書きは残る)
    private(set) var errorMessage: String?
    /// 保存できたときの一言(演出の中に出す。「『みどり』と名づけたよ」/ 相手が先だったとき「名前は『みどり』になったよ」)
    private(set) var resultNote: String?
    /// 保存が終わった(演出の中のフォームを、一言に差し替える)。begin で戻る
    private(set) var didSave = false
    /// ホームのシートを出すか
    var isSheetPresented = false

    @ObservationIgnored private let naming: PlantNaming
    /// 結果を端末の snapshot へ反映する(HomeViewModel が結ぶ)
    @ObservationIgnored var onApply: (@MainActor (PlantNameApplication) -> Void)?

    init(naming: PlantNaming) {
        self.naming = naming
    }

    // MARK: 入力の検査(サーバーと同じ規則)

    /// 打ち始めてから(空でないとき)だけ出すエラー。空のままは、エラーでなくボタンが押せないだけにする
    var validationError: PlantNameError? {
        draft.isEmpty ? nil : PlantNameRules.validate(draft)
    }

    var validationMessage: String? {
        switch validationError {
        case .empty: return Strings.Plant.nameEmptyError
        case .tooLong: return Strings.Plant.nameTooLongError
        case .invalidCharacter: return Strings.Plant.nameInvalidError
        case nil: return nil
        }
    }

    var canSubmit: Bool {
        !isSaving && PlantNameRules.validate(draft) == nil
    }

    // MARK: 開く・送る

    /// フォームを開く前の初期化(下書き・メッセージ・保存済みの印を空に戻す)。変えるときは今の名前から始める
    func begin(mode: PlantNameMode, currentName: String?) {
        self.mode = mode
        draft = mode == .rename ? (currentName ?? "") : ""
        errorMessage = nil
        resultNote = nil
        didSave = false
    }

    /// ホームのシートを開く
    func presentSheet(mode: PlantNameMode, currentName: String?) {
        begin(mode: mode, currentName: currentName)
        isSheetPresented = true
    }

    /// 名前を送る。成功したら true(演出の中では一言に差し替わり、ホームのシートは閉じる)。
    /// 失敗は false(下書きを残して、責めない文言を出す。やり直せる)
    @discardableResult
    func submit() async -> Bool {
        guard canSubmit else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let outcome = try await naming.setName(draft, mode: mode)
            switch outcome {
            case .saved(let name):
                resultNote = Strings.Plant.nameSavedNote(name)
                onApply?(.saved(name: name))
            case .adopted(let name):
                resultNote = Strings.Plant.nameAdoptedNote(name)
                onApply?(.adopted(name: name))
            }
            didSave = true
            isSheetPresented = false
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// 失敗の理由 → 責めない文言(§3.5)
    static func message(for error: Error) -> String {
        switch error as? PlantNameClientError {
        case .invalidName: return Strings.Plant.nameInvalidError
        case .noPair: return Strings.Plant.nameNoPairError
        default: return Strings.Plant.nameSaveError
        }
    }
}
