import AppKit
import SwiftUI

@MainActor
final class CalibrationModel: ObservableObject {
    /// 0...1: quanto la testa è rimasta ferma. A 1 il punto è acquisito.
    @Published var progress: Double = 0
    let screenIndex: Int
    let screenTotal: Int
    let pointIndex: Int
    let pointTotal: Int
    init(screenIndex: Int, screenTotal: Int, pointIndex: Int, pointTotal: Int) {
        self.screenIndex = screenIndex; self.screenTotal = screenTotal
        self.pointIndex = pointIndex; self.pointTotal = pointTotal
    }
}

struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel

    var body: some View {
        ZStack {
            // Il punto da guardare è al centro del pannello.
            Circle().fill(Color.accentColor.opacity(0.25)).frame(width: 96, height: 96)
            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 96, height: 96)
                .animation(.easeOut(duration: 0.15), value: model.progress)
            Circle().fill(Color.white).frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.4), radius: 2)

            VStack(spacing: 2) {
                Text("Schermo \(model.screenIndex) di \(model.screenTotal) · punto \(model.pointIndex)/\(model.pointTotal)")
                    .font(.callout.weight(.semibold))
                Text("Gira la testa verso il punto e tienila ferma")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .offset(y: 86)
        }
        .frame(width: 340, height: 240)
    }
}

/// Pannello trasparente con il punto da guardare, senza rubare il focus.
@MainActor
final class CalibrationPanel {
    let model: CalibrationModel
    private let panel: NSPanel

    /// `fraction`: posizione orizzontale del punto sullo schermo (0 = bordo sinistro, 1 = destro).
    init(screen: NSScreen, fraction: Double, screenIndex: Int, screenTotal: Int, pointIndex: Int, pointTotal: Int) {
        model = CalibrationModel(screenIndex: screenIndex, screenTotal: screenTotal,
                                 pointIndex: pointIndex, pointTotal: pointTotal)
        let size = NSSize(width: 340, height: 240)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CalibrationView(model: model))
        let cx = screen.frame.minX + screen.frame.width * fraction
        panel.setFrameOrigin(NSPoint(x: cx - size.width / 2, y: screen.frame.midY - size.height / 2))
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}
