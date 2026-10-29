import AppKit
import ApplicationServices

struct FocusedWindow {
    let bounds: CGRect        // coordinate CG (origine in alto a sinistra dello schermo principale)
    let windowNumber: Int     // CGWindowID
}

struct WindowCandidate {
    let pid: pid_t
    let bounds: CGRect
    let windowNumber: Int
}

/// Trova e porta in primo piano (dando il focus) le finestre.
/// Usa CGWindowList per sapere dove stanno le finestre e le API di Accessibilità per attivarle.
enum WindowManager {
    /// Da chiamare una volta all'avvio: evita che un'app bloccata congeli HeadSwitch per secondi.
    static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Finestre normali visibili, dalla più in alto alla più in basso.
    static func visibleWindows() -> [WindowCandidate] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        var result: [WindowCandidate] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,                 // solo finestre normali
                  let pidInt = info[kCGWindowOwnerPID as String] as? Int,
                  let number = info[kCGWindowNumber as String] as? Int,
                  pid_t(pidInt) != myPID,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80
            else { continue }
            result.append(WindowCandidate(pid: pid_t(pidInt), bounds: bounds, windowNumber: number))
        }
        return result
    }

    /// La finestra più in alto che contiene il punto (coordinate CG).
    static func windowUnder(_ point: CGPoint) -> WindowCandidate? {
        visibleWindows().first { $0.bounds.contains(point) }
    }

    /// Dà il focus alla finestra più in alto su uno schermo.
    static func focusTopWindow(on screen: NSScreen) -> FocusedWindow? {
        guard AXIsProcessTrusted() else { return nil }
        let display = CGDisplayBounds(screen.displayID)
        for w in visibleWindows() where display.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) {
            if raise(w) { return FocusedWindow(bounds: w.bounds, windowNumber: w.windowNumber) }
        }
        return nil
    }

    static func focus(_ w: WindowCandidate) -> FocusedWindow? {
        guard AXIsProcessTrusted(), raise(w) else { return nil }
        return FocusedWindow(bounds: w.bounds, windowNumber: w.windowNumber)
    }

    /// Bounds (coordinate CG) della finestra che ha il focus in questo momento.
    static func focusedWindowBounds() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef else { return nil }
        let app = appRef as! AXUIElement
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef else { return nil }
        return frame(of: winRef as! AXUIElement)
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 &&
        abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }

    // MARK: - Privato

    private static func raise(_ w: WindowCandidate) -> Bool {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        guard let window = windows.first(where: { win in
            guard let f = frame(of: win) else { return false }
            return sameFrame(f, w.bounds)
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
