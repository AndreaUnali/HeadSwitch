import SwiftUI

@main
struct HeadSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, settings: settings)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: settings.trackingEnabled ? "eye" : "eye.slash")
                if controller.diagnostics && !controller.liveInfo.isEmpty {
                    Text(controller.liveInfo).monospacedDigit()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Toggle("Cambia focus con lo sguardo", isOn: $settings.trackingEnabled)
        Text(controller.statusText)

        Divider()
        Button("Ricalibra schermi…") { controller.requestCalibration() }
            .disabled(!settings.trackingEnabled || controller.isBusy)
        Picker("Punti di calibrazione", selection: $settings.calibrationPointCount) {
            Text("5 punti (veloce)").tag(5)
            Text("9 punti (preciso)").tag(9)
        }
        Picker("Reattività", selection: $settings.dwellMilliseconds) {
            Text("Veloce").tag(300.0)
            Text("Normale").tag(400.0)
            Text("Calma").tag(650.0)
        }
        Button(settings.glowEnabled ? "✓ Luce di contorno" : "Luce di contorno") {
            settings.glowEnabled.toggle()
        }
        Button(controller.diagnostics ? "✓ Mostra angolo nella barra" : "Mostra angolo nella barra") {
            controller.diagnostics.toggle()
        }
        Button(controller.launchAtLogin ? "✓ Apri al login" : "Apri al login") {
            controller.toggleLaunchAtLogin()
        }

        Divider()
        Button("Esci") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
