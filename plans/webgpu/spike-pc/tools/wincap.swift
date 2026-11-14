// usage: wincap <windowNumber> <out.png>
// 窓が window server の上で画面に出ているか（kCGWindowIsOnscreen）を読み、ScreenCaptureKit で窓だけを撮る。
import AppKit
import CoreGraphics
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 3, let wid = UInt32(args[1]) else { print("usage: wincap <wid> <out.png>"); exit(2) }
let out = args[2]
print("preflight=\(CGPreflightScreenCaptureAccess())")
if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]], let w = info.first {
    print("onscreen=\(w[kCGWindowIsOnscreen as String] ?? "nil") layer=\(w[kCGWindowLayer as String] ?? "nil") alpha=\(w[kCGWindowAlpha as String] ?? "nil") bounds=\(w[kCGWindowBounds as String] ?? "nil") sharing=\(w[kCGWindowSharingState as String] ?? "nil")")
} else {
    print("window info: none")
}
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == CGWindowID(wid) }) else {
            print("sck: window not in shareable content (windows=\(content.windows.count))"); sem.signal(); return
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        cfg.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("sck: wrote \(out) \(img.width)x\(img.height) onScreen=\(win.isOnScreen)")
    } catch {
        print("sck: error \(error)")
    }
    sem.signal()
}
sem.wait()
