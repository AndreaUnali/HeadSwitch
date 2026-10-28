import AppKit
import SwiftUI

@MainActor
final class GlowModel: ObservableObject {
    @Published var visible = false
}

private let glowGradient = LinearGradient(colors: [.cyan, .blue, .purple],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

/// Alone che esce dai bordi della finestra, come una luce accesa sotto di essa.
/// Il pannello sta DIETRO la finestra (ordinato sotto di lei) e in più il centro è tagliato via,
/// quindi non copre mai il contenuto dell'app.
struct OuterGlowView: View {
    @ObservedObject var model: GlowModel
    let pad: CGFloat
    private let radius: CGFloat = 16

    var body: some View {
        ZStack {
            // luce ampia e morbida
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(glowGradient)
                .padding(pad - 8)
                .blur(radius: 38)
                .opacity(0.9)
            // luce più intensa vicino al bordo
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(glowGradient)
                .padding(pad - 2)
                .blur(radius: 14)
        }
        .scaleEffect(model.visible ? 1 : 0.94)      // la luce si "espande" da sotto la finestra
        .mask(
            Rectangle()
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .padding(pad)
                        .blendMode(.destinationOut)
                )
                .compositingGroup()
        )
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: model.visible ? 0.18 : 0.55), value: model.visible)
    }
}

/// Per finestre a tutto schermo (o schermo senza finestre): luce morbida lungo i bordi interni dello schermo.
struct InnerGlowView: View {
    @ObservedObject var model: GlowModel

    var body: some View {
        Rectangle()
            .strokeBorder(glowGradient, lineWidth: 70)
            .blur(radius: 45)
            .clipped()
            .opacity(model.visible ? 0.85 : 0)
            .animation(.easeOut(duration: model.visible ? 0.18 : 0.55), value: model.visible)
    }
}

@MainActor
final class FocusGlow {
    static let shared = FocusGlow()
    private var panel: NSPanel?
    private var task: Task<Void, Never>?

    func flash(window: FocusedWindow?, screen: NSScreen) {
        let display = CGDisplayBounds(screen.displayID)
        if let window {
            let visible = window.bounds.intersection(display)
            // Se la finestra occupa (quasi) tutto lo schermo l'alone esterno sarebbe fuori dallo schermo.
            if visible.width * visible.height < 0.9 * display.width * display.height {
                showOuter(window)
                return
            }
        }
        showInner(display)
    }

    private func appKitRect(_ cg: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    private func showOuter(_ w: FocusedWindow) {
        let pad: CGFloat = 90
        let rect = appKitRect(w.bounds).insetBy(dx: -pad, dy: -pad)
        present(rect: rect, level: .normal, below: w.windowNumber) { OuterGlowView(model: $0, pad: pad) }
    }

    private func showInner(_ display: CGRect) {
        present(rect: appKitRect(display), level: .floating, below: nil) { InnerGlowView(model: $0) }
    }

    private func present<V: View>(rect: NSRect, level: NSWindow.Level, below: Int?,
                                  content: (GlowModel) -> V) {
        task?.cancel()
        panel?.orderOut(nil)

        let model = GlowModel()
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: content(model))
        panel = p

        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)   // lascia che la finestra sia già davanti
            guard !Task.isCancelled else { return }
            if let below {
                p.order(.below, relativeTo: below)           // dietro alla finestra messa a fuoco
            } else {
                p.orderFrontRegardless()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            model.visible = true
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            model.visible = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            p.orderOut(nil)
        }
    }
}
