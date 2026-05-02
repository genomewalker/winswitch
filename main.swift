// WinSwitch — Spotlight-style window switcher
// Cmd+` to open, type to filter, arrows to navigate, click or Enter to switch
import AppKit

let kGrave:     CGKeyCode = 50
let kReturn:    CGKeyCode = 36
let kEscape:    CGKeyCode = 53
let kUp:        CGKeyCode = 126
let kDown:      CGKeyCode = 125
let kDelete:    CGKeyCode = 51   // backspace

// MARK: - Models

struct WinInfo {
    let ax:    AXUIElement
    let title: String
    let app:   NSRunningApplication
}

func windowsForFrontApp() -> (app: NSRunningApplication, wins: [WinInfo])? {
    guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid   = front.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    var val:  AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &val) == .success,
          let axWins = val as? [AXUIElement] else { return nil }
    let wins: [WinInfo] = axWins.compactMap { ax in
        var m: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &m)
        if m as? Bool == true { return nil }
        var t: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &t)
        return WinInfo(ax: ax, title: t as? String ?? "", app: front)
    }
    return wins.isEmpty ? nil : (front, wins)
}

func focusedIndex(in wins: [WinInfo]) -> Int {
    guard let front = wins.first?.app else { return 0 }
    let axApp = AXUIElementCreateApplication(front.processIdentifier)
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &val) == .success else { return 0 }
    let focused = val as! AXUIElement
    return wins.firstIndex { CFEqual($0.ax, focused) } ?? 0
}

// MARK: - Row

class RowButton: NSButton {
    override var wantsUpdateLayer: Bool { true }

    init(title: String, tag: Int, selected: Bool) {
        super.init(frame: .zero)
        self.tag          = tag
        isBordered        = false
        bezelStyle        = .rounded
        alignment         = .left
        lineBreakMode     = .byTruncatingMiddle
        font              = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        contentTintColor  = selected ? .white : .labelColor
        wantsLayer        = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        attributedTitle = NSAttributedString(
            string: title.isEmpty ? "(untitled)" : title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
            ]
        )
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor .constraint(greaterThanOrEqualToConstant: 320).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Overlay

class Overlay: NSPanel {
    private let blur       = NSVisualEffectView()
    private let searchIcon = NSTextField(labelWithString: "")
    private let searchLbl  = NSTextField(labelWithString: "")
    private let divider    = NSBox()
    private let stack      = NSStackView()
    private let scrollView = NSScrollView()

    var onPick: ((Int) -> Void)?   // original index

    private var allWins:   [WinInfo] = []
    private var filtered:  [(orig: Int, win: WinInfo)] = []
    private var query      = ""
    private var selRow     = 0

    init() {
        super.init(contentRect: .zero,
                   styleMask:   [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque           = false
        backgroundColor    = .clear
        level              = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate  = false
        hasShadow          = true

        blur.material     = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state        = .active
        blur.wantsLayer   = true
        blur.layer?.cornerRadius  = 14
        blur.layer?.masksToBounds = true
        contentView = blur

        // search row
        searchIcon.stringValue = "⌘`"
        searchIcon.font        = .systemFont(ofSize: 11, weight: .medium)
        searchIcon.textColor   = .tertiaryLabelColor
        searchIcon.isSelectable = false

        searchLbl.font          = .systemFont(ofSize: 14)
        searchLbl.textColor     = .labelColor
        searchLbl.isSelectable  = false
        searchLbl.stringValue   = ""
        searchLbl.placeholderString = "type to filter…"  // won't show (not editable) but documents intent

        let searchRow = NSStackView(views: [searchIcon, searchLbl])
        searchRow.orientation = .horizontal
        searchRow.spacing     = 8
        searchRow.edgeInsets  = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        searchRow.heightAnchor.constraint(equalToConstant: 40).isActive = true

        divider.boxType     = .separator
        divider.alphaValue  = 0.3

        // scrollable list
        stack.orientation = .vertical
        stack.spacing     = 2
        stack.edgeInsets  = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView              = stack
        scrollView.hasVerticalScroller       = false
        scrollView.drawsBackground           = false
        scrollView.automaticallyAdjustsContentInsets = false

        let outer = NSStackView(views: [searchRow, divider, scrollView])
        outer.orientation   = .vertical
        outer.spacing       = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor    .constraint(equalTo: blur.topAnchor),
            outer.bottomAnchor .constraint(equalTo: blur.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    // MARK: Public API (called from Switcher)

    func present(wins: [WinInfo], initialIndex: Int) {
        allWins  = wins
        query    = ""
        selRow   = 0
        applyFilter()
        // place selection at the "next" window (initialIndex already advanced by caller)
        selRow = filtered.firstIndex { $0.orig == initialIndex } ?? 0
        rebuild()
        refit()
        orderFront(nil)
    }

    func appendChar(_ c: Character) {
        query.append(c)
        applyFilter()
        selRow = 0
        rebuild(); refit()
    }

    func deleteChar() {
        guard !query.isEmpty else { return }
        query.removeLast()
        applyFilter()
        selRow = 0
        rebuild(); refit()
    }

    func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selRow = (selRow + delta + filtered.count) % filtered.count
        rebuild()
        scrollToSel()
    }

    func currentOrigIndex() -> Int? {
        filtered.indices.contains(selRow) ? filtered[selRow].orig : nil
    }

    func hide() { orderOut(nil); allWins = []; query = ""; filtered = [] }

    // MARK: Private

    private func applyFilter() {
        if query.isEmpty {
            filtered = allWins.enumerated().map { ($0, $1) }
        } else {
            let q = query.lowercased()
            filtered = allWins.enumerated().compactMap { i, w in
                w.title.lowercased().contains(q) ? (i, w) : nil
            }
        }
    }

    private func rebuild() {
        searchLbl.stringValue = query

        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        if filtered.isEmpty {
            let lbl = NSTextField(labelWithString: "No match")
            lbl.textColor  = .tertiaryLabelColor
            lbl.font       = .systemFont(ofSize: 13)
            lbl.alignment  = .center
            lbl.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stack.addArrangedSubview(lbl)
            return
        }

        for (row, item) in filtered.enumerated() {
            let btn = RowButton(title: item.win.title, tag: item.orig, selected: row == selRow)
            btn.target = self
            btn.action = #selector(rowClicked(_:))
            stack.addArrangedSubview(btn)
        }
    }

    @objc private func rowClicked(_ sender: NSButton) {
        onPick?(sender.tag)
    }

    private func scrollToSel() {
        guard selRow < stack.arrangedSubviews.count else { return }
        let view = stack.arrangedSubviews[selRow]
        stack.scrollToVisible(view.frame)
    }

    private func refit() {
        stack.layoutSubtreeIfNeeded()
        let rowH:    CGFloat = 34
        let maxRows: CGFloat = 8
        let listH   = min(CGFloat(max(filtered.count, 1)) * rowH + 12, maxRows * rowH + 12)
        let totalH  = 40 + 1 + listH    // searchRow + divider + list
        let width   = (stack.arrangedSubviews.first as? NSButton)
            .map { _ in CGFloat(340) } ?? 340
        setContentSize(NSSize(width: width + 16, height: totalH))
        scrollView.heightAnchor.constraint(equalToConstant: listH).isActive = true

        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width  / 2,
                y: screen.visibleFrame.midY - frame.height / 2 + 80
            ))
        }
    }
}

// MARK: - Switcher

class Switcher {
    private var wins:    [WinInfo] = []
    private var overlay  = Overlay()
    var isVisible = false

    init() { overlay.onPick = { [weak self] i in self?.commit(i) } }

    func trigger(reverse: Bool) {
        guard let (_, ws) = windowsForFrontApp(), ws.count > 1 else { return }

        if !isVisible {
            wins      = ws
            let start = focusedIndex(in: wins)
            let next  = reverse
                ? (start - 1 + wins.count) % wins.count
                : (start + 1) % wins.count
            isVisible = true
            overlay.present(wins: wins, initialIndex: next)
        } else {
            overlay.moveSelection(reverse ? -1 : 1)
        }
    }

    func appendChar(_ c: Character) {
        guard isVisible else { return }
        overlay.appendChar(c)
    }

    func deleteChar() {
        guard isVisible else { return }
        overlay.deleteChar()
    }

    func moveSelection(_ delta: Int) {
        guard isVisible else { return }
        overlay.moveSelection(delta)
    }

    func commitCurrent() {
        guard isVisible, let idx = overlay.currentOrigIndex() else {
            dismiss(); return
        }
        commit(idx)
    }

    func dismiss() {
        isVisible = false
        overlay.hide()
    }

    private func commit(_ idx: Int) {
        isVisible = false
        overlay.hide()
        guard idx < wins.count else { return }
        let w = wins[idx]
        AXUIElementPerformAction(w.ax, kAXRaiseAction as CFString)
        w.app.activate(options: [])
    }
}

// MARK: - Event tap

class HotkeyMonitor {
    private var tap:      CFMachPort?
    private let switcher = Switcher()

    func start() {
        // Prompt once, then poll silently
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            pollUntilTrusted()
            return
        }
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()   // shows dialog once
            pollUntilListenAccess()
            return
        }
        createTap()
    }

    private func pollUntilTrusted() {
        guard !AXIsProcessTrusted() else {
            // Now trusted — check input monitoring
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
                pollUntilListenAccess()
            } else {
                createTap()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollUntilTrusted() }
    }

    private func pollUntilListenAccess() {
        guard !CGPreflightListenEventAccess() else { createTap(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollUntilListenAccess() }
    }

    private func createTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, ref in
                Unmanaged<HotkeyMonitor>.fromOpaque(ref!).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.createTap() }
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)

        if type == .flagsChanged && !cmd {
            DispatchQueue.main.async { self.switcher.commitCurrent() }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Cmd+` — open or cycle
        if key == kGrave && cmd {
            DispatchQueue.main.async { self.switcher.trigger(reverse: shift) }
            return nil
        }

        // Navigation keys when overlay is open
        guard switcher.isVisible else { return Unmanaged.passRetained(event) }

        switch key {
        case kEscape:
            DispatchQueue.main.async { self.switcher.dismiss() }
            return nil
        case kReturn:
            DispatchQueue.main.async { self.switcher.commitCurrent() }
            return nil
        case kUp:
            DispatchQueue.main.async { self.switcher.moveSelection(-1) }
            return nil
        case kDown:
            DispatchQueue.main.async { self.switcher.moveSelection(1) }
            return nil
        case kDelete:
            DispatchQueue.main.async { self.switcher.deleteChar() }
            return nil
        default:
            // Printable character → search
            if let cgChar = event.unicodeCharacters, !cmd {
                DispatchQueue.main.async { self.switcher.appendChar(cgChar) }
                return nil
            }
        }
        return Unmanaged.passRetained(event)
    }
}

extension CGEvent {
    var unicodeCharacters: Character? {
        var buf = [UniChar](repeating: 0, count: 4)
        var len: Int = 0
        keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        guard len > 0,
              let scalar = Unicode.Scalar(buf[0]),
              scalar.value >= 32 else { return nil }
        return Character(scalar)
    }
}

// MARK: - Entry point

class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor    = HotkeyMonitor()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.3.layers.3d.top.filled",
                                            accessibilityDescription: "WinSwitch")
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
