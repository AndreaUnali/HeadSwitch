import AppKit
import ApplicationServices

struct FocusedWindow {
    let bounds: CGRect        // coordinate CG (origine in alto a sinistra dello schermo principale)
    let windowNumber: Int     // CGWindowID
}

/// Porta in primo piano (e dà il focus a) la finestra più in alto su uno schermo.
/// Usa CGWindowList per sapere quali finestre stanno su quale schermo e le API di Accessibilità per attivarle.
enum WindowManager {
    /// Ritorna la finestra messa a fuoco, o nil se sullo schermo non ce n'è una utilizzabile.
    static func focusTopWindow(on screen: NSScreen) -> FocusedWindow? {
        guard AXIsProcessTrusted() else { return nil }
        let display = CGDisplayBounds(screen.displayID)
        let myPID = ProcessInfo.processInfo.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // La lista è ordinata dalla finestra più in alto a quella più in basso.
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,                 // solo finestre normali
                  let pidInt = info[kCGWindowOwnerPID as String] as? Int,
                  let number = info[kCGWindowNumber as String] as? Int,
                  pid_t(pidInt) != myPID,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  display.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            else { continue }
            if raise(pid: pid_t(pidInt), matching: bounds) { return FocusedWindow(bounds: bounds, windowNumber: number) }
        }
        return nil
    }

    private static func raise(pid: pid_t, matching bounds: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        guard let window = windows.first(where: { w in
            guard let f = frame(of: w) else { return false }
            return abs(f.minX - bounds.minX) < 4 && abs(f.minY - bounds.minY) < 4 &&
                   abs(f.width - bounds.width) < 4 && abs(f.height - bounds.height) < 4
        }) else { return false }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
