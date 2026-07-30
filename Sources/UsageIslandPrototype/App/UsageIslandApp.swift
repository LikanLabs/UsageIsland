import AppKit
import SwiftUI

@main
struct UsageIslandPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage Island Prototype")
                    .font(.title2.weight(.semibold))
                Text("Usa el Beacon para cambiar escenarios, layouts y solicitar acceso de Accessibility.")
                    .foregroundStyle(.secondary)
                Text("Este prototipo usa datos simulados; todavía no conecta proveedores reales.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 430)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let occupancyService = MenuBarOccupancyService()
    private var islandController: IslandWindowController?
    private var beaconController: BeaconController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let island = IslandWindowController(model: model, occupancyService: occupancyService)
        let beacon = BeaconController(model: model)

        beacon.onTogglePulse = { [weak island] in island?.togglePulse() }
        beacon.onRefreshLayout = { [weak island] in island?.refreshLayout() }
        beacon.onRequestAccessibility = { [weak island] in island?.requestAccessibilityPermission() }

        islandController = island
        beaconController = beacon
        island.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        islandController?.shutdown()
        islandController = nil
        beaconController = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
