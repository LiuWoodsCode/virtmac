import AppKit
import SwiftUI
import Virtualization

// MARK: - Shared VM presentation

final class VMWindowSession: NSObject, NSWindowDelegate {
    let runtime: VMRuntime
    let window: NSWindow?
    private let displayView: VZVirtualMachineView
    private let onFinish: (Error?) -> Void
    private var stopping = false

    init(bundle: VMBundle, config: VMConfig, headless: Bool, recovery: Bool,
         onFinish: @escaping (Error?) -> Void) throws {
        runtime = try VMRuntime(bundle: bundle, config: config)
        displayView = VZVirtualMachineView()
        displayView.virtualMachine = runtime.virtualMachine
        displayView.capturesSystemKeys = true
        self.onFinish = onFinish

        if headless {
            window = nil
        } else {
            let size = NSSize(width: max(640, CGFloat(config.width) / 2),
                              height: max(480, CGFloat(config.height) / 2))
            let created = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = bundle.name
            created.contentView = displayView
            created.contentMinSize = NSSize(width: 640, height: 480)
            created.center()
            window = created
        }

        super.init()
        window?.delegate = self
        runtime.onStop = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.close()
                self.onFinish(error)
            }
        }

        window?.makeKeyAndOrderFront(nil)
        runtime.start(recovery: recovery) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.window?.close()
                    self?.onFinish(error)
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if runtime.virtualMachine.state == .running && !stopping {
            stopping = true
            runtime.requestStop { [weak self] error in
                if let error { self?.onFinish(error) }
            }
        }
        return true
    }
}

private var commandLineDelegate: CommandLineApplicationDelegate?

final class CommandLineApplicationDelegate: NSObject, NSApplicationDelegate {
    let bundle: VMBundle
    let config: VMConfig
    let headless: Bool
    let recovery: Bool
    var session: VMWindowSession?

    init(bundle: VMBundle, config: VMConfig, headless: Bool, recovery: Bool) {
        self.bundle = bundle
        self.config = config
        self.headless = headless
        self.recovery = recovery
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            log("VM: \(bundle.name)")
            log("  CPUs: \(config.cpus), RAM: \(config.memoryGB) GB")
            log("  Display: \(config.width)x\(config.height) @ \(config.ppi) PPI")
            session = try VMWindowSession(
                bundle: bundle,
                config: config,
                headless: headless,
                recovery: recovery
            ) { error in
                if let error { log("VM stopped: \(error.localizedDescription)") }
                NSApplication.shared.terminate(nil)
            }
        } catch {
            die(error.localizedDescription)
        }
    }
}

func runVirtualMachine(bundle: VMBundle, config: VMConfig, headless: Bool, recovery: Bool) {
    let application = NSApplication.shared
    let delegate = CommandLineApplicationDelegate(
        bundle: bundle,
        config: config,
        headless: headless,
        recovery: recovery
    )
    commandLineDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(headless ? .accessory : .regular)
    if !headless { application.activate(ignoringOtherApps: true) }
    application.run()
}

// MARK: - Library model

struct MachineSummary: Identifiable {
    let bundle: VMBundle
    let config: VMConfig
    let modified: Date

    var id: String { bundle.url.path }
}

struct NewMachineRequest {
    var name = "My Mac"
    var ipswPath = "latest"
    var cpus = 4
    var memoryGB = 8
    var diskGB = 64
    var width = 1920
    var height = 1200
}

@MainActor
final class LibraryModel: ObservableObject {
    let libraryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("VMs", isDirectory: true)

    @Published var machines: [MachineSummary] = []
    @Published var selectedID: String?
    @Published var search = ""
    @Published var showingCreate = false
    @Published var installing = false
    @Published var installProgress = 0.0
    @Published var installStatus = ""
    @Published var alertMessage: String?

    private var sessions: [String: VMWindowSession] = [:]

    var filteredMachines: [MachineSummary] {
        guard !search.isEmpty else { return machines }
        return machines.filter { $0.bundle.name.localizedCaseInsensitiveContains(search) }
    }

    var selectedMachine: MachineSummary? {
        machines.first { $0.id == selectedID }
    }

    init() {
        refresh()
    }

    func refresh() {
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            machines = urls.compactMap { url in
                guard url.pathExtension.lowercased() == "vbvm",
                      (try? url.resourceValues(forKeys: keys).isDirectory) == true else { return nil }
                let bundle = VMBundle(url: url)
                guard FileManager.default.fileExists(atPath: bundle.disk.path) else { return nil }
                let modified = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return MachineSummary(bundle: bundle, config: VMConfig.load(from: bundle), modified: modified)
            }
            .sorted { $0.modified > $1.modified }

            if selectedID == nil || !machines.contains(where: { $0.id == selectedID }) {
                selectedID = machines.first?.id
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func start(_ machine: MachineSummary, recovery: Bool = false) {
        if let existing = sessions[machine.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            var session: VMWindowSession?
            session = try VMWindowSession(
                bundle: machine.bundle,
                config: machine.config,
                headless: false,
                recovery: recovery
            ) { [weak self] error in
                Task { @MainActor in
                    self?.sessions[machine.id] = nil
                    if let error { self?.alertMessage = error.localizedDescription }
                }
            }
            sessions[machine.id] = session
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func reveal(_ machine: MachineSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([machine.bundle.url])
    }

    func install(_ request: NewMachineRequest) {
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            alertMessage = "Choose a VM name without slashes."
            return
        }

        let filename = trimmed.hasSuffix(".vbvm") ? trimmed : "\(trimmed).vbvm"
        let destination = libraryURL.appendingPathComponent(filename).path
        var config = VMConfig()
        config.cpus = request.cpus
        config.memoryGB = request.memoryGB
        config.diskGB = request.diskGB
        config.width = request.width
        config.height = request.height

        installing = true
        installProgress = 0
        installStatus = "Preparing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try installVM(
                    ipswPath: request.ipswPath,
                    bundlePath: destination,
                    config: config
                ) { update in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch update {
                        case .message(let message):
                            self.installStatus = message
                        case .download(let fraction):
                            self.installStatus = "Downloading macOS…"
                            self.installProgress = fraction * 0.35
                        case .restore(let fraction):
                            self.installStatus = "Installing macOS…"
                            self.installProgress = 0.35 + fraction * 0.65
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.installing = false
                    self?.showingCreate = false
                    self?.refresh()
                    self?.selectedID = destination
                }
            } catch {
                DispatchQueue.main.async {
                    self?.installing = false
                    self?.alertMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - SwiftUI

struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(model.filteredMachines, selection: $model.selectedID) { machine in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(machine.bundle.name).fontWeight(.medium)
                            Text("\(machine.config.cpus) cores · \(machine.config.memoryGB) GB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "macpro.gen3")
                            .foregroundStyle(.blue)
                    }
                    .tag(machine.id)
                    .contextMenu {
                        Button("Start") { model.start(machine) }
                        Button("Start in Recovery") { model.start(machine, recovery: true) }
                        Divider()
                        Button("Show in Finder") { model.reveal(machine) }
                    }
                }
                .searchable(text: $model.search, placement: .sidebar, prompt: "Search")

                HStack {
                    Button { model.showingCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .help("Create a virtual machine")
                    Spacer()
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let machine = model.selectedMachine {
                MachineDetailView(machine: machine, model: model)
            } else {
                EmptyLibraryView(model: model)
            }
        }
        .sheet(isPresented: $model.showingCreate) {
            CreateMachineView(model: model)
        }
        .alert(
            "AVM",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .frame(minWidth: 820, minHeight: 540)
    }
}

struct MachineDetailView: View {
    let machine: MachineSummary
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 7) {
                Text(machine.bundle.name)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(machine.bundle.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            LabeledContent("CPU", value: "\(machine.config.cpus) cores")
            LabeledContent("Memory", value: "\(machine.config.memoryGB) GB")
            LabeledContent("Display", value: "\(machine.config.width) × \(machine.config.height)")
            LabeledContent("Network", value: machine.config.network)

            HStack(spacing: 12) {
                Button {
                    model.start(machine)
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Menu {
                    Button("Start in macOS Recovery") {
                        model.start(machine, recovery: true)
                    }
                    Divider()
                    Button("Show in Finder") { model.reveal(machine) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.large)
            }
            Spacer()
        }
        .padding(44)
    }
}

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macpro.gen3")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Your VM kitchen is empty")
                .font(.title2.weight(.semibold))
            Text("Create a macOS virtual machine in ~/VMs to begin.")
                .foregroundStyle(.secondary)
            Button("Create Virtual Machine") { model.showingCreate = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

struct CreateMachineView: View {
    @ObservedObject var model: LibraryModel
    @State private var request = NewMachineRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Virtual Machine").font(.title2.weight(.semibold))
                Text("The VM will be stored in ~/VMs.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $request.name)

                Picker("Restore image", selection: $request.ipswPath) {
                    Text("Latest supported macOS").tag("latest")
                    if request.ipswPath != "latest" {
                        Text(URL(fileURLWithPath: request.ipswPath).lastPathComponent)
                            .tag(request.ipswPath)
                    }
                }
                HStack {
                    Spacer()
                    Button("Choose IPSW…") { chooseIPSW() }
                }

                Stepper("CPU cores: \(request.cpus)", value: $request.cpus, in: 2...32)
                Stepper("Memory: \(request.memoryGB) GB", value: $request.memoryGB, in: 4...128)
                Stepper("Disk: \(request.diskGB) GB", value: $request.diskGB, in: 32...2048, step: 16)

                Picker("Display", selection: displayBinding) {
                    Text("1920 × 1200").tag("1920x1200")
                    Text("2560 × 1600").tag("2560x1600")
                    Text("3840 × 2160").tag("3840x2160")
                }
            }
            .formStyle(.grouped)

            if model.installing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.installProgress)
                    Text(model.installStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.showingCreate = false }
                    .disabled(model.installing)
                Button(model.installing ? "Installing…" : "Create") {
                    model.install(request)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.installing || request.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(model.installing)
    }

    private var displayBinding: Binding<String> {
        Binding(
            get: { "\(request.width)x\(request.height)" },
            set: {
                let parts = $0.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 {
                    request.width = parts[0]
                    request.height = parts[1]
                }
            }
        )
    }

    private func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipsw")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            request.ipswPath = url.path
        }
    }
}

// MARK: - Application entry point

private var libraryDelegate: LibraryApplicationDelegate?

@MainActor
final class LibraryApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = LibraryView(model: model)
        let hostingView = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "virtMac"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
func runLibrary() {
    let application = NSApplication.shared
    let delegate = LibraryApplicationDelegate()
    libraryDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

@main
enum AVMEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            runLibrary()
        } else {
            runCommandLine(arguments: arguments)
        }
    }
}
