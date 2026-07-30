import AppKit
import Combine

@MainActor
public final class BeaconController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables: Set<AnyCancellable> = []
    public var onTogglePulse: (() -> Void)?
    public var onRefreshLayout: (() -> Void)?
    public var onRequestAccessibility: (() -> Void)?

    public init(model: AppModel) {
        self.model = model
        super.init()
        configureButton()
        observeModel()
        rebuildMenu()
    }

    private func configureButton() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePulse)
        statusItem.button?.sendAction(on: [.leftMouseUp])
        updateIcon()
    }

    private func observeModel() {
        Publishers.CombineLatest4(model.$agents, model.$providers, model.$islandIsVisible, model.$beaconPolicy)
            .sink { [weak self] _, _, _, _ in
                self?.updateVisibility()
                self?.updateIcon()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        model.$scenario
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func updateVisibility() {
        let shouldShow: Bool
        switch model.beaconPolicy {
        case .always:
            shouldShow = true
        case .never:
            shouldShow = false
        case .automatic:
            shouldShow = !model.islandIsVisible || model.attentionAgent != nil
        }

        statusItem.isVisible = shouldShow
    }

    private func updateIcon() {
        let symbol: String
        if let attention = model.attentionAgent {
            symbol = attention.status == .failed ? "xmark.circle.fill" : "exclamationmark.circle.fill"
        } else if !model.activeAgents.isEmpty {
            symbol = "bolt.circle.fill"
        } else {
            symbol = "circle"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Usage Island")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: model.isPulseOpen ? "Cerrar Pulse" : "Abrir Pulse", action: #selector(togglePulse), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let scenarios = NSMenuItem(title: "Escenario", action: nil, keyEquivalent: "")
        let scenarioMenu = NSMenu()
        for scenario in DemoScenario.allCases {
            let item = NSMenuItem(title: scenarioTitle(scenario), action: #selector(selectScenario(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scenario.rawValue
            item.state = model.scenario == scenario ? .on : .off
            scenarioMenu.addItem(item)
        }
        scenarios.submenu = scenarioMenu
        menu.addItem(scenarios)

        let layouts = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        for layout in WingPresentationMode.allCases {
            let item = NSMenuItem(title: layoutTitle(layout), action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            item.state = model.requestedLayout == layout ? .on : .off
            layoutMenu.addItem(item)
        }
        layouts.submenu = layoutMenu
        menu.addItem(layouts)

        let beaconItem = NSMenuItem(title: "Beacon", action: nil, keyEquivalent: "")
        let beaconMenu = NSMenu()
        for policy in BeaconPolicy.allCases {
            let item = NSMenuItem(title: beaconTitle(policy), action: #selector(selectBeaconPolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.rawValue
            item.state = model.beaconPolicy == policy ? .on : .off
            beaconMenu.addItem(item)
        }
        beaconItem.submenu = beaconMenu
        menu.addItem(beaconItem)

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Recalcular espacio", action: #selector(refreshLayout), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let permission = NSMenuItem(title: "Activar espaciado adaptativo…", action: #selector(requestAccessibility), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de Usage Island", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func togglePulse() {
        statusItem.menu = nil
        onTogglePulse?()
        DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
    }

    @objc private func selectScenario(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scenario = DemoScenario(rawValue: raw) else { return }
        model.applyScenario(scenario)
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let layout = WingPresentationMode(rawValue: raw) else { return }
        model.requestedLayout = layout
    }

    @objc private func selectBeaconPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = BeaconPolicy(rawValue: raw) else { return }
        model.beaconPolicy = policy
    }

    @objc private func refreshLayout() {
        onRefreshLayout?()
    }

    @objc private func requestAccessibility() {
        onRequestAccessibility?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func scenarioTitle(_ scenario: DemoScenario) -> String {
        switch scenario {
        case .normal: "Normal"
        case .critical: "Cuota crítica"
        case .waiting: "Espera aprobación"
        case .error: "Error"
        }
    }

    private func layoutTitle(_ layout: WingPresentationMode) -> String {
        switch layout {
        case .automatic: "Automático"
        case .full: "Completo"
        case .compact: "Compacto"
        case .minimal: "Mínimo"
        case .hidden: "Oculto"
        }
    }

    private func beaconTitle(_ policy: BeaconPolicy) -> String {
        switch policy {
        case .automatic: "Automático"
        case .always: "Siempre"
        case .never: "Nunca"
        }
    }
}
