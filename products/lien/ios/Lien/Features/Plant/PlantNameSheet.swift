// PlantNameSheet.swift — ホームから開く、植物の名前のシート(issue #57 / docs/GROWTH.md §5.3)
//
// ホームの植物の下の「名前をつける」(まだ名前が無いとき。最初の「ふたば」の演出を閉じたあとも残る)と、
// 名前の行(あとから変えるとき)から開く。フォームは演出の中と共通(PlantNameFormView)。
// 保存できたら、モデル(PlantNamingModel)がシートを閉じる。やめる = 閉じるだけ(何も保存しない)。

import SwiftUI

struct PlantNameSheet: View {
    let model: PlantNamingModel

    var body: some View {
        NavigationStack {
            ScrollView {
                PlantNameFormView(model: model)
                    .padding(LienSpacing.l)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Plant.nameCancel) {
                        model.isSheetPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
