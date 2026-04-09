import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MediaButtonInterceptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(model)
        } label: {
            Label {
                Text(model.config.menuBarTitle)
            } icon: {
                Image(nsImage: StatusBarIconFactory.image(for: model.micState))
            }
        }
    }
}

private struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MediaButtonInterceptor")
                .font(.headline)
            Text("Mic: \(model.micState.displayName)")
                .foregroundStyle(.secondary)

            Button(model.micState == .muted ? "Unmute Microphone" : "Mute Microphone") {
                model.toggleMicMute()
            }

            Divider()

            Button("Open Settings") {
                model.openSettingsWindow()
            }

            Button(model.config.startAtLogin ? "Disable Start at Login" : "Enable Start at Login") {
                model.config.startAtLogin.toggle()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}
