// PlantNameFormView.swift — 植物の名前を付ける・変えるフォーム(issue #57 / docs/GROWTH.md §5.3)
//
// 最初の「ふたば」の演出の中(StageCelebrationView)と、ホームのシート(PlantNameSheet)で共有する。
// 状態は PlantNamingModel(入力中の名前・検査・送信・失敗)。8文字まで(Unicode コードポイント数 — サーバーと同じ数え方)。
// 「どちらかが先につけると、その名前に決まります。あとからいつでも変えられます」と添える(先に付けた人の名前に決まる)。
// 失敗しても下書きは残り、責めない文言を出してやり直せる(§3.5)。

import SwiftUI

struct PlantNameFormView: View {
    @Bindable var model: PlantNamingModel

    var body: some View {
        // 観測する状態は body の中で読む(Binding の getter の中で読むと、変化が画面の更新に結びつかないことがある)
        let message = model.validationMessage ?? model.errorMessage
        let isRename = model.mode == .rename
        VStack(spacing: LienSpacing.s) {
            Text(isRename ? Strings.Plant.renameTitle : Strings.Plant.nameTitle)
                .font(.headline)

            TextField(Strings.Plant.namePlaceholder, text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { Task { await model.submit() } }
                .disabled(model.isSaving)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LienColors.gentleAlert)
                    .multilineTextAlignment(.center)
            }

            Text(Strings.Plant.nameNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await model.submit() }
            } label: {
                Group {
                    if model.isSaving {
                        Text(Strings.Plant.nameSaving)
                    } else {
                        Text(isRename ? Strings.Plant.renameSubmit : Strings.Plant.nameSubmit)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
        }
    }
}
