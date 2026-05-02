// WinSwitch — Cmd+Tab for apps, Cmd+` for windows within an app
// No SCStream, no screen capture. AXUIElement + NSWorkspace only.
import AppKit

let kTab:   CGKeyCode = 48
let kGrave: CGKeyCode = 50

// MARK: - Models

struct AppInfo {
    let app: NSRunningApplication
    var title: String { app.localizedName ?? "?" }
    var icon:  NSImage? { app.icon }
}

struct WinInfo {
    let ax: AXUIElement
    let title: String
}

// MARK: - Helpers

func runningApps() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isHidden || $0.activationPolicy == .regular }
        .filter { $0.activationPolicy == .regular }
        .map { AppInfo(app: $0) }
}

func windowsFor(pid: pid_t) -> [WinInfo] {
    let axApp = AXUIElementCreateApplication(pid)
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &val) == .success,
          let wins = val as? [AXUIElement] else { return [] }
    return wins.compactMap { ax -> WinInfo? in
        var minVal: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minVal)
        if minVal as? Bool == true { return nil }
        var t: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &t)
        return WinInfo(ax: ax, title: t as? String ?? "")
    }
}

func focusedWinIndex(in wins: [WinInfo], pid: pid_t) -> Int {
    let axApp = AXUIElementCreateApplication(pid)
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &val) == .success else { return 0 }
    let focused = val as! AXUIElement
    return wins.firstIndex { CFEqual($0.ax, focused) } ?? 0
}

// MARK: - Row view (used for both apps and windows)

class RowView: NSView {
    var onTap: (() -> Void)?

    init(icon: NSImage?, title: String, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            layer?.cornerRadius    = 8
        }

        var leading: CGFloat = 10
        if let icon {
            let iv = NSImageView(image: icon)
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor .constraint(equalTo: leadingAnchor, constant: 10),
                iv.centerYAnchor .constraint(equalTo: centerYAnchor),
                iv.widthAnchor   .constraint(equalToConstant: 22),
                iv.heightAnchor  .constraint(equalToConstant: 22),
            ])
            leading = 38
        }

        let lbl = NSTextField(labelWithString: title.isEmpty ? "(untitled)" : title)
        lbl.font          = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        lbl.textColor     = selected ? .white : .labelColor
        lbl.lineBreakMode = .byTruncatingTail
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor .constraint(equalTo: leadingAnchor,  constant: leading),
            lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            lbl.centerYAnchor .constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor .constraint(greaterThanOrEqualToConstant: 280),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with _: NSEvent) { onTap?() }
}

// MARK: - Overlay panel

class Overlay: NSPanel {
    private let stack = NSStackView()
    var onPick: ((Int) -> Void)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque           = false
        backgroundColor    = .clear
        level              = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate  = false

        let blur = NSVisualEffectView()
        blur.material     = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state        = .active
        blur.wantsLayer   = true
        blur.layer?.cornerRadius    = 14
        blur.layer?.masksToBounds   = true
        contentView = blur

        stack.orientation  = .vertical
        stack.spacing      = 3
        stack.edgeInsets   = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor    .constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor .constraint(equalTo: blur.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])
    }

    func reload<T>(items: [(icon: NSImage?, title: String)], selected idx: Int, tag: T) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let row = RowView(icon: item.icon, title: item.title, selected: i == idx)
            row.onTap = { [weak self] in self?.onPick?(i) }
            stack.addArrangedSubview(row)
        }
        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        setContentSize(fit)
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - fit.width  / 2,
                y: screen.visibleFrame.midY - fit.height / 2
            ))
        }
        orderFront(nil)
    }

    func hide() { orderOut(nil) }
}

// MARK: - Switcher state machine

enum SwitcherMode {
    case apps([AppInfo])
    case windows(pid: pid_t, app: NSRunningApplication, wins: [WinInfo])
}

class Switcher {
    private var mode:     SwitcherMode?
    private var selected: Int = 0
    private let overlay   = Overlay()

    init() { overlay.onPick = { [weak self] i in self?.commit(i) } }

    func triggerApps(reverse: Bool) {
        let apps: [AppInfo]
        if case .apps(let a) = mode { apps = a } else {
            apps = runningApps()
            guard apps.count > 1 else { return }
            // start selection at current frontmost
            let front = NSWorkspace.shared.frontmostApplication
            selected  = apps.firstIndex { $0.app == front } ?? 0
            mode      = .apps(apps)
        }
        let n = apps.count
        selected = reverse ? (selected - 1 + n) % n : (selected + 1) % n
        overlay.reload(
            items: apps.map { (icon: $0.icon, title: $0.title) },
            selected: selected, tag: 0
        )
    }

    func triggerWindows(reverse: Bool) {
        let wins: [WinInfo]
        let pid:  pid_t
        let frontApp: NSRunningApplication
        if case .windows(let p, let a, let w) = mode {
            wins = w; pid = p; frontApp = a
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            frontApp = app
            pid      = app.processIdentifier
            wins     = windowsFor(pid: pid)
            guard wins.count > 1 else { return }
            selected  = focusedWinIndex(in: wins, pid: pid)
            mode      = .windows(pid: pid, app: frontApp, wins: wins)
        }
        let n = wins.count
        selected = reverse ? (selected - 1 + n) % n : (selected + 1) % n
        overlay.reload(
            items: wins.map { (icon: nil, title: $0.title) },
            selected: selected, tag: 0
        )
    }

    func commitIfVisible() {
        guard mode != nil else { return }
        commit(selected)
    }

    private func commit(_ idx: Int) {
        defer { mode = nil; overlay.hide() }
        switch mode {
        case .apps(let apps):
            guard idx < apps.count else { return }
            apps[idx].app.activate(options: [])
        case .windows(_, let app, let wins):
            guard idx < wins.count else { return }
            AXUIElementPerformAction(wins[idx].ax, kAXRaiseAction as CFString)
            app.activate(options: [])
        case nil:
            break
        }
    }
}

extension SwitcherMode? {
    var isActive: Bool { if case .none = self { return false }; return true }
}

// MARK: - Global event tap

class HotkeyMonitor {
    private var tap:      CFMachPort?
    private let switcher = Switcher()

    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        tap = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ref in
                Unmanaged<HotkeyMonitor>.fromOpaque(ref!).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags  = event.flags
        let cmd    = flags.contains(.maskCommand)
        let shift  = flags.contains(.maskShift)

        if type == .keyDown && cmd {
            let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            switch key {
            case kTab:
                DispatchQueue.main.async { self.switcher.triggerApps(reverse: shift) }
                return nil   // consume — replace system Cmd+Tab
            case kGrave:
                DispatchQueue.main.async { self.switcher.triggerWindows(reverse: shift) }
                return nil
            default: break
            }
        }

        if type == .flagsChanged && !cmd {
            // Cmd released → activate selection
            DispatchQueue.main.async { self.switcher.commitIfVisible() }
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - Entry point

class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = HotkeyMonitor()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "square.3.layers.3d.top.filled",
                                accessibilityDescription: "WinSwitch")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit WinSwitch", action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
        monitor.start()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app      = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
