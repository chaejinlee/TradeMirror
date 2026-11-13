import Foundation
import Vision
import UIKit

/// 券商截图 → 文本行。**全部在本机跑,不联网。**
///
/// 用 Apple 的 Vision 而不是把图传给 LLM,理由不只是省钱:
/// **券商截图里有账户余额和持仓**,传出去这件事本身就不该做,
/// 而且一旦联网,「不收集数据」的隐私标签就不成立了。
enum ScreenshotOCR {

    /// 识别失败时返回空数组,**不抛错也不编内容** —— 让上层老实告诉用户「没认出来」。
    static func recognize(_ image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                // ★ 不能只按纵坐标排序 —— 券商表格「标签在左、值在右」是**两个独立文本块**,
                //   它们的 midY 只差 0.0008,谁在前取决于浮点比较。
                //   实测踩到:值排在标签前面,解析器读到「成交数量」后看下一行,
                //   拿到的是下一行的值(2.170 被当成了张数)。
                //   ⇒ 交给 LineAssembler:先按纵坐标分行,组内再按横坐标从左到右拼。
                let blocks = obs.compactMap { o -> LineAssembler.Block? in
                    guard let t = o.topCandidates(1).first?.string else { return nil }
                    let b = o.boundingBox
                    return LineAssembler.Block(text: t, midY: b.midY, minX: b.minX, height: b.height)
                }
                cont.resume(returning: LineAssembler.assemble(blocks))
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["zh-Hans", "en-US"]
            // ★ 必须关掉语言纠正:开着会把 "2.170" 之类的数字"纠正"坏,
            //   而这个场景里数字比词句重要得多。
            req.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
            catch { cont.resume(returning: []) }
        }
    }
}
