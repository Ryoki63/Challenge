// QRCodeGenerator.swift — 招待 URL の QR コード生成(T11)
//
// CoreImage の CIFilter.qrCodeGenerator()(CIFilterBuiltins)を使う。外部依存ゼロ。
// 出力はピクセル等倍の CGImage。View 側は .resizable().interpolation(.none) で
// 整数倍拡大して表示する(にじみ禁止 — DESIGN §3.5 のドット絵と同じ扱い)。

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeGenerator {
    /// 文字列(招待の webUrl 等)を QR コード画像にする。
    /// - Parameters:
    ///   - string: エンコードする文字列(UTF-8)
    ///   - scale: 1モジュール(QR の1マス)あたりのピクセル数(整数倍のみ)
    /// - Returns: 生成できなければ nil(空文字等。呼び出し側は QR 表示を省略する)
    static func generate(from string: String, scale: Int = 8) -> CGImage? {
        guard !string.isEmpty, scale >= 1 else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // 誤り訂正 M(15%)。招待 URL は短く、画面間の読み取りには十分
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        let scaled = output.transformed(by: transform)
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
