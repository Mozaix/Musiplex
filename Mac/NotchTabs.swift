import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: Stores

/// Files parked in the notch to drag somewhere else later. Only paths are
/// kept — nothing is copied or moved.
@MainActor @Observable
final class Shelf {
    private(set) var files: [URL] = (UserDefaults.standard.stringArray(forKey: "shelf") ?? [])
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    func add(_ urls: [URL]) {
        let new = urls.filter { url in !files.contains(url) }
        guard !new.isEmpty else { return }
        files.insert(contentsOf: new, at: 0)
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files = []
        save()
    }

    private func save() { UserDefaults.standard.set(files.map(\.path), forKey: "shelf") }
}

/// Recent text you copied. Checks the pasteboard once a second (it only does
/// work when something changed), skips passwords marked as concealed, and
/// keeps history in memory only — never on disk.
@MainActor @Observable
final class ClipboardHistory {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let date: Date
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.4
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        let types = board.types ?? []
        let secret = types.contains { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" }
        guard !secret, let text = board.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0.text == text }
        items.insert(Item(text: text, date: Date()), at: 0)
        if items.count > 40 { items.removeLast(items.count - 40) }
    }

    func copy(_ item: Item) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(item.text, forType: .string)
        changeCount = board.changeCount
        items.removeAll { $0.id == item.id }
        items.insert(Item(text: item.text, date: Date()), at: 0)
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clear() { items = [] }
}

@MainActor @Observable
final class NotesStore {
    struct Note: Codable, Identifiable, Hashable {
        var id = UUID()
        var text = ""
        var edited = Date()
        var title: String {
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return first.trimmingCharacters(in: .whitespaces).isEmpty ? "New note" : first
        }
    }

    var notes: [Note] = []
    var selection: UUID?
    @ObservationIgnored private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiplex/notes.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        }
        if notes.isEmpty { notes = [Note()] }
        selection = notes.first?.id
    }

    func binding(for id: UUID) -> Binding<String> {
        Binding(get: { [weak self] in self?.notes.first { $0.id == id }?.text ?? "" },
                set: { [weak self] value in
                    guard let self, let i = self.notes.firstIndex(where: { $0.id == id }) else { return }
                    self.notes[i].text = value
                    self.notes[i].edited = Date()
                    self.scheduleSave()
                })
    }

    func add() {
        let note = Note()
        notes.insert(note, at: 0)
        selection = note.id
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [Note()] }
        if selection == id { selection = notes.first?.id }
        scheduleSave()
    }

    /// Coalesced writes so typing doesn't hit the disk on every key.
    private func scheduleSave() {
        saveTask?.cancel()
        let notes = notes, url = url
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(notes) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// Currency conversion with free daily exchange rates (cached 12 h).
@MainActor @Observable
final class Money {
    static let currencies = ["USD", "EUR", "GBP", "SAR", "AED", "QAR", "KWD", "BHD", "OMR", "EGP", "JOD",
                             "TRY", "CAD", "AUD", "CHF", "JPY", "CNY", "INR", "PKR", "MAD"]
    var amount = "100"
    var from = UserDefaults.standard.string(forKey: "moneyFrom") ?? "USD" { didSet { UserDefaults.standard.set(from, forKey: "moneyFrom") } }
    var to = UserDefaults.standard.string(forKey: "moneyTo") ?? "EUR" { didSet { UserDefaults.standard.set(to, forKey: "moneyTo") } }
    private(set) var rates: [String: Double] = UserDefaults.standard.dictionary(forKey: "moneyRates") as? [String: Double] ?? [:]
    private(set) var updated = UserDefaults.standard.object(forKey: "moneyUpdated") as? Date
    private(set) var loading = false
    private(set) var failed = false

    var result: Double? {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")),
              let a = rates[from], let b = rates[to], a > 0 else { return nil }
        return value / a * b
    }

    func swap() { (from, to) = (to, from) }

    func refreshIfNeeded() {
        guard !loading else { return }
        if let updated, Date().timeIntervalSince(updated) < 12 * 3600, !rates.isEmpty { return }
        loading = true
        failed = false
        Task {
            defer { loading = false }
            struct Response: Decodable { let result: String; let rates: [String: Double] }
            guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(Response.self, from: data),
                  response.result == "success" else {
                failed = true
                return
            }
            rates = response.rates
            updated = Date()
            UserDefaults.standard.set(rates, forKey: "moneyRates")
            UserDefaults.standard.set(updated, forKey: "moneyUpdated")
        }
    }
}

enum AirDrop {
    /// Opens the system AirDrop sheet for these files.
    @MainActor static func send(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }
}

// MARK: Tab views

struct NotchMusic: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        let state = session.state
        if let track = model.currentTrack {
            HStack(spacing: 18) {
                ArtworkView(id: track.id, radius: 12)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    ScrubBar(duration: track.duration, position: { session.livePosition },
                             onSeek: { model.send("seek", value: $0) }, playing: state.isPlaying)
                    HStack(spacing: 22) {
                        icon("shuffle", active: state.shuffle) { model.send("shuffle") }
                        icon("backward.fill", size: 17) { model.send("prev") }
                        Button { model.send("toggle") } label: {
                            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 38, height: 38).background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        icon("forward.fill", size: 17) { model.send("next") }
                        icon(state.repeatMode == .one ? "repeat.1" : "repeat", active: state.repeatMode != .off) { model.send("repeat") }
                        Spacer(minLength: 0)
                        Menu {
                            ForEach(model.server.devices) { device in
                                Button {
                                    model.send("device", text: device.id)
                                } label: {
                                    Label(device.id == "mac" ? "This Mac" : device.name,
                                          systemImage: state.activeDevice == device.id ? "checkmark" : device.symbol)
                                }
                            }
                        } label: {
                            Label(state.activeDevice == "mac" ? "Mac" : model.server.name(of: state.activeDevice),
                                  systemImage: state.activeDevice == "mac" ? "laptopcomputer" : "iphone")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list").font(.system(size: 24)).foregroundStyle(Theme.dim)
                Text("Nothing is playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func icon(_ name: String, size: CGFloat = 13, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white.opacity(0.85))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NotchFileBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shelf = model.shelf
        if shelf.files.isEmpty {
            DropHint(symbol: "tray.and.arrow.down.fill", title: "Drop files here",
                     subtitle: "Park files in the notch, then drag them out wherever you need them.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.files, id: \.self) { url in
                            FileChip(url: url)
                        }
                    }
                }
                HStack {
                    Text("\(shelf.files.count) file\(shelf.files.count == 1 ? "" : "s") · drag out to use")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("AirDrop All") { AirDrop.send(shelf.files) }
                    Button("Clear") { shelf.clear() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct FileChip: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 54, height: 54)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 84)
        }
        .padding(6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { AirDrop.send([url]) }
            Divider()
            Button("Remove from File Box") { model.shelf.remove(url) }
        }
        .help(url.path)
    }
}

struct NotchClipboard: View {
    @Environment(AppModel.self) private var model
    @State private var copied: UUID?

    var body: some View {
        let history = model.clipboard
        if history.items.isEmpty {
            DropHint(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                     subtitle: "Text you copy shows up here. Click one to copy it again. Passwords are skipped.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(history.items) { item in
                            HStack(spacing: 8) {
                                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 12)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(copied == item.id ? "Copied" : item.date.formatted(.relative(presentation: .numeric)))
                                    .font(.system(size: 10)).foregroundStyle(copied == item.id ? Theme.accent : Theme.dim)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                history.copy(item)
                                copied = history.items.first?.id
                            }
                            .contextMenu {
                                Button("Copy") { history.copy(item) }
                                Button("Remove") { history.remove(item) }
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear") { history.clear() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct NotchNotes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.notes
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Button { store.add() } label: {
                    Label("New", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.notes) { note in
                            Text(note.title).font(.system(size: 11)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(store.selection == note.id ? Color.white.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { store.selection = note.id }
                                .contextMenu { Button("Delete") { store.delete(note.id) } }
                        }
                    }
                }
            }
            .frame(width: 140)

            if let id = store.selection {
                TextEditor(text: store.binding(for: id))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .id(id)
            }
        }
    }
}

struct NotchMoney: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var money = model.money
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Amount", text: $money.amount)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(width: 160)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                currency($money.from)
                Button { money.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                currency($money.to)
            }
            if let result = money.result {
                Text(result.formatted(.currency(code: money.to).precision(.fractionLength(2))))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.gradient)
                    .contentTransition(.numericText())
            } else if money.loading {
                ProgressView().controlSize(.small)
            } else {
                Text(money.failed ? "Couldn't get exchange rates — check your connection." : "Enter an amount")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            if let updated = money.updated {
                Text("Rates from \(updated.formatted(date: .abbreviated, time: .shortened)) · open.er-api.com")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { money.refreshIfNeeded() }
    }

    private func currency(_ value: Binding<String>) -> some View {
        Picker("", selection: value) {
            ForEach(Money.currencies, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 84)
    }
}

struct NotchAirDrop: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            DropHint(symbol: "dot.radiowaves.up.forward", title: "Drop files to AirDrop",
                     subtitle: "Drop anything here and pick a nearby iPhone, iPad or Mac.")
            HStack(spacing: 10) {
                Button("Choose Files…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = true
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK { AirDrop.send(panel.urls) }
                }
                if !model.shelf.files.isEmpty {
                    Button("AirDrop File Box (\(model.shelf.files.count))") { AirDrop.send(model.shelf.files) }
                }
                if let track = model.currentTrack, let url = model.library.url(for: track.id) {
                    Button("AirDrop This Song") { AirDrop.send([url]) }
                }
            }
            .buttonStyle(PillButton(filled: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropHint: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(Theme.gradient)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

struct NotchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.notch.settings
        let screens = NSScreen.screens
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                heading("SHOW THE NOTCH ON")
                ForEach(screens, id: \.displayID) { screen in
                    let builtIn = NotchSettings.isBuiltIn(screen)
                    Toggle(isOn: Binding(get: { settings.isOn(screen) }, set: { settings.set(screen, on: $0) })) {
                        Label(NotchSettings.name(screen) + (builtIn ? " · built-in" : ""),
                              systemImage: builtIn ? "laptopcomputer" : "display")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(NotchSwitch())
                }
                Text("On \(settings.chosenScreens.count) of \(screens.count) display\(screens.count == 1 ? "" : "s"). Displays without a notch get a slim bar at the top.")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                heading("BEHAVIOUR")
                Toggle("Hide when nothing is playing", isOn: Binding(get: { settings.hideWhenIdle },
                                                                    set: { settings.hideWhenIdle = $0 }))
                    .toggleStyle(NotchSwitch()).font(.system(size: 12))
                Text("While hidden, open it from the Musiplex icon in the menu bar.")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show the notch", isOn: Binding(get: { model.notchEnabled }, set: { model.notchEnabled = $0 }))
                    .toggleStyle(NotchSwitch())
                heading("CROSSFADE").padding(.top, 4)
                CrossfadePicker(value: model.session.state.crossfade) { model.send("crossfade", value: $0) }.font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).kerning(1.5).foregroundStyle(Theme.dim)
    }
}

/// A switch that stays readable in the notch (system switches turn grey in
/// windows that aren't focused, and the notch never takes focus).
struct NotchSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.18)))
                    Circle().fill(.white).padding(2)
                }
                .frame(width: 30, height: 17)
                .animation(.spring(duration: 0.25), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Off / 2 / 4 / 6 / 8 / 12 seconds, as small pills.
struct CrossfadePicker: View {
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach([0.0, 2, 4, 6, 8, 12], id: \.self) { option in
                let on = option == value
                Button { set(option) } label: {
                    Text(option == 0 ? "Off" : "\(Int(option))s")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
                        .foregroundStyle(on ? .black : .white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
