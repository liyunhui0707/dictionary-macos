import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CryptoKit

enum ScreenContextStatus: String, Codable {
    case permissionMissing, windowUnavailable, captureUnavailable, sourceChanged, pixelsChanged, textUnavailable, recognitionFailed, timedOut, needsConfirmation
}

struct BooksScreenSnapshot {
    let windowID: CGWindowID
    let windowBounds: CGRect
    let region: CGRect
    let pointer: CGPoint
    let digest: Data
    let image: CGImage?

    func matches(_ other: Self) -> Bool {
        windowID == other.windowID && windowBounds == other.windowBounds && region == other.region &&
        pointer == other.pointer && digest == other.digest
    }
}

@MainActor
enum BooksScreenFallback {
    static func capture(enabled: Bool, isBooks: Bool, permission: Bool, nativeHasSentence: Bool,
                        isCurrent: () -> Bool,
                        snapshot: () async -> BooksScreenSnapshot?,
                        native: () async throws -> CapturedContext,
                        recognize: (BooksScreenSnapshot, String) async -> ScreenTextRecognition.Result) async throws -> CapturedContext {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let before: BooksScreenSnapshot?
        if enabled && isBooks && permission && !nativeHasSentence && isCurrent() { before = await snapshot() }
        else { before = nil }
        let original = try await native()
        func rejected(_ status:ScreenContextStatus) -> CapturedContext {
            var result=original; result.diagnostics.screenContext=status; return result
        }
        guard enabled && isBooks && !nativeHasSentence, original.containingSentence == nil else { return original }
        guard permission else { return rejected(.permissionMissing) }
        guard let before else { return rejected(.captureUnavailable) }
        guard isCurrent(), !Task.isCancelled else { return rejected(.sourceChanged) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return rejected(.timedOut) }
        guard let after = await snapshot() else { return rejected(.captureUnavailable) }
        guard before.matches(after) else { return rejected(.pixelsChanged) }
        let recognition = await recognize(after, original.target)
        guard isCurrent(), !Task.isCancelled else { return rejected(.sourceChanged) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return rejected(.timedOut) }
        let lines: [ScreenTextLine]
        switch recognition {
        case .recognized(let value): lines = value
        case .failed: return rejected(.recognitionFailed)
        case .timedOut: return rejected(.timedOut)
        }
        guard let sentence = ScreenTextContext.sentence(target:original.target,pointer:after.pointer,lines:lines) else { return rejected(.textUnavailable) }
        guard let final = await snapshot() else { return rejected(.captureUnavailable) }
        guard after.matches(final), isCurrent(), !Task.isCancelled else { return rejected(.pixelsChanged) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return rejected(.timedOut) }
        var details = original.diagnostics
        details.strategy = .screenOCR
        details.reason = nil // Native sentence failure no longer describes the recovered OCR proposal.
        details.screenContext = .needsConfirmation
        return CapturedContext(target:original.target,context:sentence,containingSentence:sentence,diagnostics:details,
            capture:.init(reliability:.heuristic,method:.screenOCR))
    }
}

/// Only explicit settings actions request permission. Capture never prompts.
@MainActor
final class BooksScreenSettings: ObservableObject {
    static let preference = "booksScreenContextEnabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var permissionGranted = false
    private let persist: (Bool) -> Void
    init(enabled: Bool = false, persist: @escaping (Bool) -> Void = { _ in }) {
        self.enabled=enabled; self.persist=persist
    }
    func setEnabled(_ value: Bool) { enabled=value; persist(value) }
    func refresh() { permissionGranted=CGPreflightScreenCaptureAccess() }
    func requestPermission() { _ = CGRequestScreenCaptureAccess(); refresh() }
}

@MainActor
enum BooksScreenCapture {
    static func snapshot(source: NSRunningApplication, isCurrent: () -> Bool,
                         failed:(ScreenContextStatus)->Void = { _ in }) async -> BooksScreenSnapshot? {
        guard CGPreflightScreenCaptureAccess() else { failed(.permissionMissing); return nil }
        guard source.bundleIdentifier == "com.apple.iBooksX", isCurrent(),
              let bounds = focusedWindowBounds(pid:source.processIdentifier),
              let pointer = CGEvent(source:nil)?.location, bounds.contains(pointer) else { failed(.windowUnavailable); return nil }
        let content: SCShareableContent? = await bounded { done in
            SCShareableContent.getExcludingDesktopWindows(true,onScreenWindowsOnly:true) { value,_ in done(value) }
        }
        guard isCurrent(), !Task.isCancelled else { failed(.sourceChanged); return nil }
        guard let content else { failed(.captureUnavailable); return nil }
        let windows=content.windows.filter { $0.owningApplication?.processID == source.processIdentifier && $0.frame == bounds }
        guard windows.count == 1, let window=windows.first else { failed(.windowUnavailable); return nil }
        let region=CGRect(x:pointer.x-500,y:pointer.y-180,width:1000,height:360).intersection(bounds)
        guard region.width >= 160, region.height >= 80 else { failed(.windowUnavailable); return nil }
        let filter=SCContentFilter(desktopIndependentWindow:window)
        let config=SCStreamConfiguration()
        // A single-window filter ignores sourceRect. Capture only that window,
        // then create an owned local crop; never fall back to the whole display.
        config.width=Int(bounds.width*2); config.height=Int(bounds.height*2)
        guard config.width > 0, config.height > 0, config.width <= 8192, config.height <= 8192,
              config.width*config.height <= 16_777_216 else { failed(.windowUnavailable); return nil }
        config.showsCursor=false; config.ignoreShadowsSingleWindow=true; config.capturesAudio=false
        let image: CGImage? = await bounded { done in
            SCScreenshotManager.captureImage(contentFilter:filter,configuration:config) { image,_ in done(image) }
        }
        guard isCurrent(), !Task.isCancelled, focusedWindowBounds(pid:source.processIdentifier) == bounds,
              CGEvent(source:nil)?.location == pointer else { failed(.sourceChanged); return nil }
        guard let image, image.width == config.width, image.height == config.height,
              let crop=localCrop(image:image,window:bounds,region:region), let bytes=crop.image.dataProvider?.data else { failed(.captureUnavailable); return nil }
        return BooksScreenSnapshot(windowID:window.windowID,windowBounds:bounds,region:crop.region,
            pointer:CGPoint(x:pointer.x-crop.region.minX,y:pointer.y-crop.region.minY),
            digest:Data(SHA256.hash(data:bytes as Data)),image:crop.image)
    }

    static func localCrop(image:CGImage,window:CGRect,region:CGRect) -> (image:CGImage,region:CGRect)? {
        guard window.width > 0, window.height > 0, window.contains(region) else { return nil }
        let sx=CGFloat(image.width)/window.width, sy=CGFloat(image.height)/window.height
        let pixels=CGRect(x:(region.minX-window.minX)*sx,y:(region.minY-window.minY)*sy,
            width:region.width*sx,height:region.height*sy).integral
            .intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard pixels.width > 0, pixels.height > 0, let cropped=image.cropping(to:pixels),
              let bitmap=CGContext(data:nil,width:Int(pixels.width),height:Int(pixels.height),bitsPerComponent:8,
                bytesPerRow:Int(pixels.width)*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.draw(cropped,in:CGRect(x:0,y:0,width:pixels.width,height:pixels.height))
        guard let owned=bitmap.makeImage() else { return nil }
        return (owned,CGRect(x:window.minX+pixels.minX/sx,y:window.minY+pixels.minY/sy,
            width:pixels.width/sx,height:pixels.height/sy))
    }

    private static func focusedWindowBounds(pid:pid_t) -> CGRect? {
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.2)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window=raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window,0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&position) == .success,
              AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero, dimensions=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&point), AXValueGetValue(size as! AXValue,.cgSize,&dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin:point,size:dimensions)
    }

    private static func bounded<Value>(_ operation: (@escaping (Value?) -> Void) -> Void) async -> Value? {
        await withCheckedContinuation { continuation in
            let reply=ScreenCaptureReply(continuation)
            DispatchQueue.global().asyncAfter(deadline:.now()+1.5) { reply.finish(nil) }
            operation { reply.finish($0) }
        }
    }
}

private final class ScreenCaptureReply<Value>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Value?,Never>?
    init(_ continuation:CheckedContinuation<Value?,Never>) { self.continuation=continuation }
    func finish(_ value:Value?, beforeResume: () -> Void = {}) {
        lock.lock(); let pending=continuation; continuation=nil; lock.unlock()
        guard let pending else { return }
        beforeResume()
        pending.resume(returning:value)
    }
}

enum ScreenTextRecognition {
    enum Result {
        case recognized([ScreenTextLine]), failed, timedOut
    }

    static func recognize(snapshot:BooksScreenSnapshot,target:String,timeout:TimeInterval=3) async -> Result {
        guard let image=snapshot.image else { return .failed }
        let request=VNRecognizeTextRequest()
        return await perform(timeout:timeout,cancel:{request.cancel()}) { done in
            DispatchQueue.global(qos:.userInitiated).async {
                done(read(image:image,snapshot:snapshot,target:target,request:request))
            }
        }
    }

    /// A late native callback cannot overwrite the timeout or resume a caller twice.
    static func perform(timeout:TimeInterval,cancel:@escaping ()->Void,
                        operation:(@escaping (Result)->Void)->Void) async -> Result {
        guard timeout.isFinite, timeout > 0 else { return .timedOut }
        return await withCheckedContinuation { continuation in
            let reply=ScreenCaptureReply<Result>(continuation)
            DispatchQueue.global().asyncAfter(deadline:.now()+timeout) {
                reply.finish(.timedOut,beforeResume:cancel)
            }
            operation { reply.finish($0) }
        } ?? .failed
    }

    private static func read(image:CGImage,snapshot:BooksScreenSnapshot,target:String,
                             request:VNRecognizeTextRequest) -> Result {
            request.recognitionLevel = .accurate
            request.recognitionLanguages=["en-US"]; request.usesLanguageCorrection=false
            guard (try? VNImageRequestHandler(cgImage:image).perform([request])) != nil,
                  let observations=request.results, observations.count <= 200 else { return .failed }
            func rect(_ box:CGRect) -> CGRect {
                CGRect(x:box.minX*snapshot.region.width,y:(1-box.maxY)*snapshot.region.height,
                       width:box.width*snapshot.region.width,height:box.height*snapshot.region.height)
            }
            let pattern="(?<![\\p{L}\\p{M}\\p{N}_])"+NSRegularExpression.escapedPattern(for:target)+"(?![\\p{L}\\p{M}\\p{N}_])"
            guard let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { return .failed }
            return .recognized(observations.compactMap { observation -> ScreenTextLine? in
                guard let candidate=observation.topCandidates(1).first, candidate.string.utf16.count <= 2000 else { return nil }
                let text=candidate.string
                let words=regex.matches(in:text,range:NSRange(location:0,length:text.utf16.count)).compactMap { match -> ScreenTextWord? in
                    guard let range=Range(match.range,in:text), let bounds=try? candidate.boundingBox(for:range) else { return nil }
                    return ScreenTextWord(text:String(text[range]),bounds:rect(bounds.boundingBox))
                }
                return ScreenTextLine(text:text,bounds:rect(observation.boundingBox),confidence:candidate.confidence,words:words)
            })
    }
}
