import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import DictionaryApp

/// Opt-in latency evidence only. No screen access, app switching or model calls.
struct ScreenRecognitionTimingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTIONARY_OCR_TIMING"] == "1"),
          .timeLimit(.minutes(1)))
    func recordFirstAndRepeatedRecognitionOfProductionSizedSyntheticPixels() async throws {
        let bitmap = try #require(CGContext(data: nil, width: 2000, height: 720, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 2000, height: 720))
        let source = "The bank approved a loan. Later, they rested on the bank of the river."
        let text = NSAttributedString(string: source, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 42, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        bitmap.textPosition = CGPoint(x: 50, y: 400)
        CTLineDraw(CTLineCreateWithAttributedString(text), bitmap)
        let image = try #require(bitmap.makeImage())
        let snapshot = BooksScreenSnapshot(windowID: 1, windowBounds: CGRect(x: 0, y: 0, width: 1000, height: 360),
            region: CGRect(x: 0, y: 0, width: 1000, height: 360), pointer: .zero, digest: Data(), image: image)
        for index in 1...2 {
            let start = ContinuousClock.now
            // Observe the actual work beyond the old three-second cutoff, with
            // a bounded eight-second request. This is not a Books capture pass.
            let result = await ScreenTextRecognition.recognize(snapshot: snapshot, target: "bank", timeout: 8)
            let elapsed = start.duration(to: .now)
            let matched: Bool
            let status: String
            switch result {
            case .recognized(let lines):
                matched = lines.contains { $0.text == source && $0.words.count == 2 }
                status = "recognized"
            case .failed: matched = false; status = "failed"
            case .timedOut: matched = false; status = "timedOut"
            }
            print("OCR_TIMING sample=\(index) pixels=2000x720 timeout=8 elapsed=\(elapsed) status=\(status) matched=\(matched)")
            #expect(matched)
        }
    }
}
