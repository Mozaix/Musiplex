import AppKit
import Observation
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case music, calendar, files, clipboard, notes, money, airdrop, settings, power
    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Music"
        case .calendar: "Calendar"
        case .files: "File Box"
        case .clipboard: "Clipboard"
        case .notes: "Notes"
        case .money: "Money"
        case .airdrop: "AirDrop"
        case .settings: "Settings"
        case .power: "Power"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .calendar: "calendar"
        case .files: "tray.full.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .notes: "note.text"
        case .money: "dollarsign.circle.fill"
        case .airdrop: "dot.radiowaves.up.forward"
        case .settings: "gearshape.fill"
        case .power: "bolt.fill"
        }
    }

    /// Tabs either side of the camera notch.
    static let left: [NotchTab] = [.music, .calendar, .files, .clipboard, .notes]
    static let right: [NotchTab] = [.money, .airdrop, .settings]
}

@MainActor @Observable
final class NotchState {
    var expanded = false
    var tab = NotchTab.music
    /// Size of the physical notch (or a stand-in on displays without one).
    var notchSize = CGSize(width: 200, height: 32)
    var hasNotch = false
    /// Somebody is dragging files toward the notch.
    var dropTargeted = false
    /// Nothing playing and "hide when nothing is playing" is on.
    var idleHidden = false
    /// Called when files are dragged over the closed notch.
    @ObservationIgnored var onDragEnter: (() -> Void)?
    static let panelSize = CGSize(width: 680, height: 250)
}

/// What the notch's Settings tab controls.
@MainActor @Observable
final class NotchSettings {
    /// Names of the displays that get a notch. Empty = just the built-in one.
    var displays: [String] = UserDefaults.standard.stringArray(forKey: "notchDisplays") ?? [] {
        didSet { UserDefaults.standard.set(displays, forKey: "notchDisplays"); onChange?() }
    }
    /// Hide the notch completely while no music is playing.
    var hideWhenIdle = UserDefaults.standard.bool(forKey: "notchHideWhenIdle") {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "notchHideWhenIdle"); onChange?() }
    }
    /// Show the Mac's battery in the open notch.
    var showBattery = UserDefaults.standard.object(forKey: "notchBattery") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBattery, forKey: "notchBattery") }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    static func name(_ screen: NSScreen) -> String { screen.localizedName }
    static func isBuiltIn(_ screen: NSScreen) -> Bool { CGDisplayIsBuiltin(screen.displayID) != 0 }

    /// The displays that should show a notch right now.
    var chosenScreens: [NSScreen] {
        let screens = NSScreen.screens
        let picked = screens.filter { displays.contains(Self.name($0)) }
        if !picked.isEmpty { return picked }
        return [screens.first(where: Self.isBuiltIn) ?? screens.first].compactMap { $0 }
    }

    func isOn(_ screen: NSScreen) -> Bool { chosenScreens.contains(screen) }

    func set(_ screen: NSScreen, on: Bool) {
        var names = chosenScreens.map(Self.name)
        if on { names.append(Self.name(screen)) } else { names.removeAll { $0 == Self.name(screen) } }
        // Keep at least one display.
        if names.isEmpty { return }
        displays = Array(Set(names)).sorted()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Borderless panel that can take keyboard focus (for Notes) without
/// activating Musiplex or stealing focus while you just hover.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Never let AppKit nudge the notch down from the top edge of a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        // Clicking inside lets the notch take typing (Notes, Money) without activating the app.
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// Container that tells us when the mouse enters or leaves the notch window,
/// whichever display it's on and whether or not Musiplex is the active app.
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// One notch on one display. While closed, the window is exactly the size of
/// the notch (so the rest of the menu bar works normally); hovering grows it.
@MainActor
final class NotchWindow {
    let state = NotchState()
    let panel: NotchPanel
    private(set) var screenName: String
    private var screen: NSScreen
    private var collapseTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    /// Opened from the menu bar: stays open until the mouse visits and leaves (or 8 s).
    private var pinned = false
    private unowned let model: AppModel

    init(screen: NSScreen, model: AppModel) {
        self.model = model
        self.screen = screen
        screenName = NotchSettings.name(screen)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        let container = HoverView()
        // Fixed-size window; don't let SwiftUI's preferred size drive it
        // (that causes an AppKit constraint loop and a crash).
        let host = NSHostingView(rootView: NotchView(state: state).environment(model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onEnter = { [weak self] in MainActor.assumeIsolated { self?.mouseEntered() } }
        container.onExit = { [weak self] in MainActor.assumeIsolated { self?.mouseExited() } }
        state.onDragEnter = { [weak self] in self?.dragEntered() }
        panel.contentView = container
        host.frame = container.bounds
        place(on: screen)
    }

    func place(on screen: NSScreen) {
        self.screen = screen
        screenName = NotchSettings.name(screen)
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            state.hasNotch = true
        } else {
            state.notchSize = CGSize(width: 190, height: max(NSStatusBar.system.thickness, 26))
            state.hasNotch = false
        }
        panel.setFrame(state.expanded ? expandedFrame : collapsedFrame, display: true)
    }

    /// Width of the closed notch: the notch itself, plus artwork/waveform wings while music plays.
    /// Paused or stopped, it's just the notch (hovering still opens it).
    static func collapsedWidth(notch: CGSize, playing: Bool) -> CGFloat { notch.width + (playing ? 92 : 0) }

    private var collapsedFrame: NSRect {
        let f = screen.frame
        let w = Self.collapsedWidth(notch: state.notchSize, playing: model.session.state.isPlaying && model.currentTrack != nil)
        return NSRect(x: f.midX - w / 2, y: f.maxY - state.notchSize.height, width: w, height: state.notchSize.height)
    }

    private var expandedFrame: NSRect {
        let f = screen.frame, size = NotchState.panelSize
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    /// Keeps the closed notch the right width as songs start and stop.
    func refit() {
        guard !state.expanded, shrinkTask == nil else { return }
        if panel.frame != collapsedFrame { panel.setFrame(collapsedFrame, display: true) }
    }

    func show(_ visible: Bool) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            setExpanded(false, animated: false)
            panel.orderOut(nil)
        }
    }

    private func mouseEntered() {
        pinned = false
        collapseTask?.cancel()
        collapseTask = nil
        if !state.expanded { setExpanded(true) }
    }

    private func mouseExited() {
        guard state.expanded, !pinned else { return }
        collapseTask?.cancel()
        // Small grace period so brushing past the edge doesn't snap it shut.
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }
    }

    /// Something is being dragged onto the notch: open it so it can be dropped.
    func dragEntered() {
        if !state.expanded { setExpanded(true) }
    }

    func open(tab: NotchTab) {
        state.tab = tab
        panel.orderFrontRegardless()
        pinned = true
        setExpanded(true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.pinned else { return }
            self.pinned = false
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }
    }

    func setExpanded(_ open: Bool, animated: Bool = true) {
        shrinkTask?.cancel()
        shrinkTask = nil
        if open {
            // Grow the window first, then animate the card open inside it.
            panel.setFrame(expandedFrame, display: true)
            withAnimation(animated ? .spring(response: 0.38, dampingFraction: 0.82) : nil) { state.expanded = true }
        } else {
            withAnimation(animated ? .spring(response: 0.34, dampingFraction: 0.9) : nil) { state.expanded = false }
            if panel.isKeyWindow {
                // Hand typing back to whatever app you were using.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            // Shrink the window once the closing animation is done.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(animated ? 380 : 0))
                guard let self, !Task.isCancelled else { return }
                self.shrinkTask = nil
                if !self.state.expanded { self.panel.setFrame(self.collapsedFrame, display: true) }
            }
        }
    }

    func close() {
        collapseTask?.cancel()
        shrinkTask?.cancel()
        panel.orderOut(nil)
    }
}

/// Runs one notch per chosen display and keeps them in sync with the
/// settings and with playback (for "hide when nothing is playing").
@MainActor
final class NotchController {
    let settings = NotchSettings()
    private(set) var windows: [NotchWindow] = []
    private var monitors: [Any] = []
    private var screenObserver: Any?
    private var running = false
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        settings.onChange = { [weak self] in self?.rebuild() }
    }

    func start() {
        guard !running else { return }
        running = true
        rebuild()

        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func stop() {
        running = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.forEach { $0.close() }
        windows = []
    }

    /// Matches the notch windows to the chosen displays.
    func rebuild() {
        guard running else { return }
        let screens = settings.chosenScreens
        var kept: [NotchWindow] = []
        for screen in screens {
            if let existing = windows.first(where: { $0.screenName == NotchSettings.name(screen) }) {
                existing.place(on: screen)
                kept.append(existing)
            } else {
                kept.append(NotchWindow(screen: screen, model: model))
            }
        }
        for old in windows where !kept.contains(where: { $0 === old }) { old.close() }
        windows = kept
        refresh()
    }

    /// Keeps the notches the right size as music starts and stops. They stay
    /// in place while paused (invisible on displays without a notch when
    /// "hide when nothing is playing" is on) so hovering still opens them.
    func refresh() {
        guard running else { return }
        let idle = !model.session.state.isPlaying
        for w in windows {
            w.state.idleHidden = idle && settings.hideWhenIdle
            w.show(true)
            w.refit()
        }
    }

    /// Opens the notch on the main notch display (from the menu bar), even if
    /// it's hidden because nothing is playing.
    /// Switches the open notch(es) to a tab.
    func select(_ tab: NotchTab) {
        for w in windows where w.state.expanded { w.state.tab = tab }
    }

    func open(tab: NotchTab = .music) {
        if !running { start() }
        (windows.first { $0.state.hasNotch } ?? windows.first)?.open(tab: tab)
    }

    /// Hidden switch for screenshots: `-notchSnapshot <folder>` opens the real
    /// notch, captures every tab to PNG files and quits. Loads a song paused,
    /// without playing any audio.
    func snapshot(to folder: String) {
        if let first = model.library.recentAlbums.first?.tracks.first {
            model.session.state.queue = [first.id]
            model.session.state.index = 0
        }
        start()
        Task {
            @MainActor func capture(_ name: String) {
                guard let view = windows.first?.panel.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("notch-\(name).png"))
                }
            }
            try? await Task.sleep(for: .seconds(3))
            capture("collapsed")
            guard let w = windows.first else { NSApp.terminate(nil); return }
            w.setExpanded(true)
            for tab in NotchTab.allCases {
                w.state.tab = tab
                try? await Task.sleep(for: .milliseconds(900))
                capture(tab.rawValue)
            }
            // The menu bar popup, rendered in an off-screen window.
            let popup = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 300, height: 560), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            let host = NSHostingView(rootView: MenuBarPlayer().environment(model))
            popup.contentView = host
            popup.setContentSize(host.fittingSize)
            popup.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1200))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("menubar.png"))
            }
            NSApp.terminate(nil)
        }
    }
}

// MARK: Views

struct NotchView: View {
    @Environment(AppModel.self) private var model
    let state: NotchState

    var body: some View {
        let expanded = state.expanded
        let playing = model.currentTrack != nil && model.session.state.isPlaying
        let notch = state.notchSize
        // On displays without a real notch, the idle stand-in fades away (still hoverable).
        let ghost = !expanded && !playing && state.idleHidden && !state.hasNotch
        let collapsedWidth = NotchWindow.collapsedWidth(notch: notch, playing: playing)
        let width = expanded ? NotchState.panelSize.width : collapsedWidth
        let height = expanded ? NotchState.panelSize.height : notch.height

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 28 : 12, bottomTrailingRadius: expanded ? 28 : 12,
                                   style: .continuous)
                .fill(.black.opacity(ghost ? 0.004 : 1))
                .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 18, y: 8)

            if expanded {
                ExpandedNotch(state: state)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if playing {
                CollapsedWings(notchWidth: notch.width, height: notch.height)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { false }, set: { if $0, !state.expanded { state.onDragEnter?() } })) { _ in false }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 28 : 12, bottomTrailingRadius: expanded ? 28 : 12,
                                          style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

/// While collapsed and playing: artwork on the left of the notch, a live
/// waveform on the right, like the iPhone's Dynamic Island.
private struct CollapsedWings: View {
    @Environment(AppModel.self) private var model
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(id: model.currentTrack?.id, radius: 5)
                .frame(width: height - 10, height: height - 10)
                .frame(width: 46)
            Spacer(minLength: notchWidth)
            // Static on purpose: an endlessly animating symbol kept the whole
            // notch re-rendering and cost ~20% CPU.
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.gradient)
                .frame(width: 46)
        }
        .frame(height: height)
    }
}

struct ExpandedNotch: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: NotchState

    var body: some View {
        VStack(spacing: 0) {
            // The strip level with the camera notch: tabs split evenly either
            // side of it (4 left, 3 + battery right), so it looks symmetrical.
            let side = (NotchState.panelSize.width - state.notchSize.width) / 2
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(NotchTab.left) { tabButton($0) }
                }
                .frame(width: side)
                Color.clear.frame(width: state.notchSize.width)
                HStack(spacing: 6) {
                    ForEach(NotchTab.right) { tabButton($0) }
                    if model.notch.settings.showBattery, model.battery.hasBattery { BatteryBadge() }
                }
                .frame(width: side)
            }
            .frame(height: max(state.notchSize.height, 26))

            Group {
                switch state.tab {
                case .music: NotchMusic()
                case .calendar: NotchCalendar()
                case .files: NotchFileBox()
                case .clipboard: NotchClipboard()
                case .notes: NotchNotes()
                case .money: NotchMoney()
                case .airdrop: NotchAirDrop()
                case .settings: NotchSettingsView()
                case .power: NotchPower()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        // Files dragged onto any tab land in the File Box (or get AirDropped on that tab).
        .onDrop(of: [.fileURL], isTargeted: $state.dropTargeted) { providers in
            loadFileURLs(providers) { urls in
                if state.tab == .airdrop { AirDrop.send(urls) } else {
                    model.shelf.add(urls)
                    state.tab = .files
                }
            }
            return true
        }
    }
}

extension ExpandedNotch {
    func tabButton(_ tab: NotchTab) -> some View {
        Button { state.tab = tab } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 22)
                .foregroundStyle(state.tab == tab ? .white : Theme.dim)
                .background(state.tab == tab ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

/// Battery level and charging state, top right of the open notch.
struct BatteryBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let battery = model.battery
        Button { model.notch.select(.power) } label: { badge(battery) }
            .buttonStyle(.plain)
            .help("Power: watts in and out")
            .task {
                // Only polls while the notch is open (the badge is only shown then).
                while !Task.isCancelled {
                    model.battery.readPower()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }

    private func badge(_ battery: Battery) -> some View {
        HStack(spacing: 4) {
            Image(systemName: battery.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(color(battery), .white.opacity(0.5))
                .font(.system(size: 13))
            Text("\(battery.level ?? 0)%")
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            // Watts in from the charger, or out of the battery.
            let w = battery.powerIn > 0.5 ? battery.powerIn : -max(battery.systemLoad, -battery.batteryWatts)
            if abs(w) > 0.5 {
                Text(String(format: "%@%.0fW", w > 0 ? "+" : "−", abs(w)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(w > 0 ? Color.green : Color.orange)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(Color.white.opacity(0.001))
        .contentShape(Rectangle())
    }

    private func color(_ b: Battery) -> Color {
        if b.charging || b.pluggedIn { return .green }
        if let l = b.level, l <= 20 { return .red }
        return .white
    }
}

/// Resolves dropped file providers to URLs on the main actor.
func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let result = urls
        MainActor.assumeIsolated { done(result) }
    }
}
