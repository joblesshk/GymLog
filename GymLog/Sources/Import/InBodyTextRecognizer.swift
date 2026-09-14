import Foundation
import Vision
import CoreGraphics
import ImageIO

public enum InBodyTextRecognizerError: Error, LocalizedError {
    case couldNotDecodeImage
    case visionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotDecodeImage: return "Couldn't read that photo."
        case .visionFailed(let reason): return "Text recognition failed: \(reason)"
        }
    }
}

/// CONTRACT-M7.md §2.2: the on-device OCR layer -- `CGImage` in,
/// `[RecognizedToken]` out, no business logic (see `InBodyReportParser` for
/// that). `VNRecognizeTextRequest` runs entirely on-device; this file makes
/// zero network calls, which is exactly why `InBodyReportParser` is kept as
/// a pure function fed by this one's output rather than the two being
/// merged -- it lets the parser's own tests run without Vision at all.
public enum InBodyTextRecognizer {
    /// `orientation`: pass the photo's own `CGImagePropertyOrientation` (not
    /// always `.up` -- a photo taken in portrait on an iPhone is stored
    /// with orientation metadata, not pre-rotated pixels). Getting this
    /// wrong doesn't crash anything, it just silently produces garbage
    /// bounding boxes.
    public static func recognizeTokens(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> [RecognizedToken] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction pulls plausible-looking numbers toward
        // dictionary words -- "40.3" -> "40.5", "8" -> "B". This is THE
        // easiest way to silently corrupt a scanned health number, and
        // there is no scenario in this feature where "helpfully" correcting
        // a digit is wanted.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.revision = VNRecognizeTextRequestRevision3
        // `minimumTextHeight` intentionally left at its default: the
        // reference-range annotations are small text, and raising this
        // threshold would drop them from recognition entirely (which
        // wouldn't even help -- the parser needs to SEE them to exclude
        // them by content, not have them silently absent).

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw InBodyTextRecognizerError.visionFailed(error.localizedDescription)
        }

        guard let observations = request.results else { return [] }
        let imageSize = CGSize(width: image.width, height: image.height)

        var tokens: [RecognizedToken] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { word, range, _, _ in
                guard let word, !word.isEmpty else { return }
                guard let boxObservation = try? candidate.boundingBox(for: range) else { return }
                // Vision's normalized rect has its origin at the BOTTOM-left
                // with Y increasing upward; `VNImageRectForNormalizedRect`
                // converts to pixel coordinates but keeps that same
                // bottom-left origin. Every other coordinate this feature
                // touches (test fixtures, the parser's geometry) uses a
                // top-left origin with Y increasing downward, so this is
                // the one place that flip happens -- do it here, once, so
                // nothing downstream has to think about it again.
                let pixelRect = VNImageRectForNormalizedRect(boxObservation.boundingBox, Int(imageSize.width), Int(imageSize.height))
                let flippedRect = CGRect(
                    x: pixelRect.minX,
                    y: imageSize.height - pixelRect.maxY,
                    width: pixelRect.width,
                    height: pixelRect.height
                )
                tokens.append(RecognizedToken(text: word, rect: flippedRect, confidence: candidate.confidence))
            }
        }
        return tokens
    }
}
