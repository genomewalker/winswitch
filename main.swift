// WinSwitch — Cmd+` cycles windows of the frontmost app across all Spaces.
// AltTab-style grid UI, no screenshots, no background work.
import AppKit

// MARK: - Private APIs

typealias CGSConnectionID = UInt32
typealias CGSSpaceID      = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ ax: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// MARK: - Space helpers

private func visibleSpaceIDs() -> Set<CGSSpaceID> {
    let cid = CGSMainConnectionID()
    guard let screens = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
    return Set(screens.compactMap { ($0["Current Space"] as? [String: Any])?["id64"] as? CGSSpaceID })
}

private func switchToWindowSpace(_ cgId: CGWindowID) {
    let cid = CGSMainConnectionID()
    let spaces = CGSCopySpacesForWindows(cid, 7, [cgId] as CFArray) as! [CGSSpaceID]
    guard let target = spaces.first else { return }
    guard let screens = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return }
    for screen in screens {
        guard let slist = screen["Spaces"] as? [[String: Any]],
              slist.contains(where: { $0["id64"] as? CGSSpaceID == target }),
              let display = screen["Display Identifier"] as? String else { continue }
        CGSManagedDisplaySetCurrentSpace(cid, display as CFString, target)
        return
    }
}

// MARK: - Focus (AltTab technique)

private func focusWindow(cgId: CGWindowID, pid: pid_t) {
    var psn = ProcessSerialNumber()
    GetProcessForPID(pid, &psn)
    _SLPSSetFrontProcessWithOptions(&psn, cgId, 0x200)
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8; bytes[0x3a] = 0x10
    withUnsafeBytes(of: cgId) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01; SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02; SLPSPostEventRecordTo(&psn, &bytes)
}

// MARK: - Logging

private let logFile = "/tmp/winswitch.log"
private func wlog(_ s: String) {
    let line = s + "\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: logFile)
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else { try? data.write(to: url) }
}

// MARK: - Window model

struct WinInfo {
    let cgId:        CGWindowID
    let ax:          AXUIElement?
    let title:       String
    let app:         NSRunningApplication
    let isMinimized: Bool
}

// MARK: - Window discrimination (from AltTab's WindowDiscriminator)

private enum WindowKind { case normal, minimized, rejected }

private func classifyWindow(_ ax: AXUIElement) -> WindowKind {
    var rv: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &rv)
    let role = rv as? String ?? ""
    guard role == kAXWindowRole || role.isEmpty else { return .rejected }

    var sv: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &sv)
    let sub = sv as? String
    if sub == kAXUnknownSubrole || sub == "AXSystemDialog" { return .rejected }

    // check minimized before size — minimized windows report a tiny/zero size
    var mv: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &mv)
    if mv as? Bool == true { return .minimized }

    // AltTab rule: width > 100, height > 50 (only for non-minimized)
    var szv: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXSizeAttribute as CFString, &szv)
    if let szv = szv {
        var sz = CGSize.zero
        AXValueGetValue(szv as! AXValue, .cgSize, &sz)
        if sz.width > 0 && (sz.width < 100 || sz.height < 50) { return .rejected }
    }

    return .normal
}

private func axWindowInfo(_ ax: AXUIElement, app: NSRunningApplication) -> WinInfo? {
    let kind = classifyWindow(ax)
    guard kind != .rejected else { return nil }
    var tv: AnyObject?
    AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &tv)
    let title = (tv as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "(untitled)"
    var cgId: CGWindowID = 0
    _AXUIElementGetWindow(ax, &cgId)
    return WinInfo(cgId: cgId, ax: ax, title: title, app: app, isMinimized: kind == .minimized)
}

private func offSpaceWindows(for pids: Set<pid_t>, visible: Set<CGSSpaceID>) -> [WinInfo] {
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                         as? [[String: Any]] else { return [] }
    let cid = CGSMainConnectionID()
    return list.compactMap { info -> WinInfo? in
        guard let pid  = info[kCGWindowOwnerPID  as String] as? pid_t, pids.contains(pid) else { return nil }
        guard (info[kCGWindowLayer as String] as? Int) == 0                                else { return nil }
        guard (info[kCGWindowAlpha as String] as? Double ?? 0) > 0                         else { return nil }
        guard let b = info[kCGWindowBounds as String] as? [String: Any],
              let w = b["Width"]  as? Double, let h = b["Height"] as? Double,
              w > 100, h > 50                                                              else { return nil }
        guard let cgId = info[kCGWindowNumber as String] as? CGWindowID, cgId != 0         else { return nil }
        let wSpaces = CGSCopySpacesForWindows(cid, 7, [cgId] as CFArray) as! [CGSSpaceID]
        guard !wSpaces.isEmpty, !wSpaces.contains(where: { visible.contains($0) })         else { return nil }
        let rawTitle  = info[kCGWindowName      as String] as? String ?? ""
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        let title = rawTitle.isEmpty ? (ownerName.isEmpty ? "Full Screen" : ownerName) : rawTitle
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return WinInfo(cgId: cgId, ax: nil, title: title, app: app, isMinimized: false)
    }
}

func windowsForFrontApp() -> [WinInfo]? {
    guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
    let bid = front.bundleIdentifier
    let siblings: [NSRunningApplication] = bid.map { b in
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == b && $0.activationPolicy == .regular }
    } ?? [front]

    var wins: [WinInfo] = []
    for app in siblings {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var val: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &val) == .success,
           let axWins = val as? [AXUIElement] {
            wins += axWins.compactMap { axWindowInfo($0, app: app) }
        }
    }

    let pids     = Set(siblings.map { $0.processIdentifier })
    let visible  = visibleSpaceIDs()
    let knownIds = Set(wins.map { $0.cgId })
    let offSpace = offSpaceWindows(for: pids, visible: visible).filter { !knownIds.contains($0.cgId) }
    wins += offSpace

    wlog("\(front.localizedName ?? "?") — \(wins.count) wins (\(offSpace.count) off-space): \(wins.map(\.title))")
    return wins.isEmpty ? nil : wins
}

func focusedIndex(in wins: [WinInfo]) -> Int {
    guard let front = NSWorkspace.shared.frontmostApplication else { return 0 }
    let axApp = AXUIElementCreateApplication(front.processIdentifier)
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &val) == .success else { return 0 }
    let focused = val as! AXUIElement
    return wins.firstIndex { $0.ax.map { CFEqual($0, focused) } ?? false } ?? 0
}

// MARK: - UI constants
//
//  ┌─────────────────────────────────────────┐
//  │  kPad                                   │
//  │  [cell] [cell] [cell]  ← icon row       │  kCellH
//  │  kInfoGap                               │
//  │       Window Title Here                 │  kTitleH  (shared label)
//  │  kTitleGap                              │
//  │    App Name  ·  ↗ Other Space           │  kSubH    (shared label)
//  │  kPad                                   │
//  └─────────────────────────────────────────┘

private let kCellW:       CGFloat = 86
private let kCellH:       CGFloat = 86
private let kIconW:       CGFloat = 64
private let kCellSpacing: CGFloat = 4
private let kPad:         CGFloat = 14
private let kInfoGap:     CGFloat = 10
private let kTitleH:      CGFloat = 19
private let kTitleGap:    CGFloat = 3
private let kSubH:        CGFloat = 16

// MARK: - IconCellView (icon + highlight only — no text)

private let kOffSpaceAmber   = NSColor(red: 1.0,  green: 0.62, blue: 0.08, alpha: 1)
private let kMinimizedPurple = NSColor(red: 0.62, green: 0.45, blue: 1.0,  alpha: 1)

class IconCellView: NSView {
    var onPick: (() -> Void)?
    private let isOffSpace:   Bool
    private let isMinimized:  Bool
    private var isSelected = false

    private let highlight = NSView()
    private let glowView  = NSView()   // amber shadow carrier for off-space icons
    private let iconView  = NSImageView()

    private let kHInset:  CGFloat = 5
    private let kBorderW: CGFloat = 2.5

    init(win: WinInfo) {
        isOffSpace  = (win.ax == nil)
        isMinimized = win.isMinimized
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        // selection ring
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius    = 14
        highlight.layer?.borderWidth     = kBorderW
        highlight.layer?.borderColor     = NSColor.clear.cgColor
        highlight.layer?.backgroundColor = NSColor.clear.cgColor

        // glow carrier: same frame as icon, shadow only, fades in when selected
        let glowColor = isOffSpace ? kOffSpaceAmber : kMinimizedPurple
        glowView.wantsLayer = true
        glowView.layer?.backgroundColor = NSColor.clear.cgColor
        glowView.layer?.shadowColor   = glowColor.cgColor
        glowView.layer?.shadowRadius  = 16
        glowView.layer?.shadowOpacity = 0      // hidden until selected
        glowView.layer?.shadowOffset  = .zero

        // app icon
        iconView.wantsLayer           = true
        iconView.layer?.cornerRadius  = 14
        iconView.layer?.masksToBounds = true
        iconView.imageScaling         = .scaleProportionallyUpOrDown
        iconView.alphaValue           = isMinimized ? 0.5 : 1.0
        if let raw = win.app.icon {
            let ic = raw.copy() as! NSImage
            ic.size = NSSize(width: kIconW * 2, height: kIconW * 2)
            iconView.image = ic
        }
        iconView.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowOffset     = NSSize(width: 0, height: -2)
            s.shadowColor      = NSColor.black.withAlphaComponent(0.4)
            return s
        }()

        addSubview(highlight)
        addSubview(glowView)
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor .constraint(equalToConstant: kCellW),
            heightAnchor.constraint(equalToConstant: kCellH),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height

        highlight.frame = CGRect(x: kHInset, y: kHInset,
                                 width: w - kHInset * 2, height: h - kHInset * 2)

        let iconX = (w - kIconW) / 2
        let iconY = (h - kIconW) / 2
        let iconFrame = CGRect(x: iconX, y: iconY, width: kIconW, height: kIconW)
        iconView.frame = iconFrame
        glowView.frame = iconFrame
        // shadowPath needed so CALayer renders glow even with clear backgroundColor
        if isOffSpace {
            glowView.layer?.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: iconFrame.size),
                cornerWidth: 14, cornerHeight: 14, transform: nil)
        }
    }

    func setSelected(_ sel: Bool) {
        guard sel != isSelected else { return }
        isSelected = sel
        let accent: NSColor = isOffSpace ? kOffSpaceAmber
                            : isMinimized ? kMinimizedPurple
                            : NSColor.controlAccentColor
        let ringColor: CGColor = sel ? accent.cgColor : NSColor.clear.cgColor
        let fillColor: CGColor = sel ? accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.highlight.layer?.borderColor     = ringColor
            self.highlight.layer?.backgroundColor = fillColor
        }
        // amber glow fades in/out with selection
        let needsGlow = sel && (isOffSpace || isMinimized)
        let glowAnim = CABasicAnimation(keyPath: "shadowOpacity")
        glowAnim.fromValue = glowView.layer?.shadowOpacity
        glowAnim.toValue   = needsGlow ? Float(0.75) : Float(0)
        glowAnim.duration  = 0.14
        glowAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowView.layer?.shadowOpacity = needsGlow ? 0.75 : 0
        glowView.layer?.add(glowAnim, forKey: "glowFade")
    }

    override func mouseDown(with _: NSEvent)    { onPick?() }
    override func mouseEntered(with _: NSEvent) {
        if !isSelected {
            highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        }
    }
    override func mouseExited(with _: NSEvent) {
        if !isSelected {
            highlight.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Overlay panel (AltTab style: dark vibrancy, icon grid + shared info strip)

class Overlay: NSPanel {
    var onPick: ((Int) -> Void)?
    private let blur          = NSVisualEffectView()
    private let iconRow       = NSStackView()
    private let titleLabel    = NSTextField()
    private let subtitleLabel = NSTextField()
    private var wins:   [WinInfo] = []
    private var selIdx = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; hasShadow = true
        appearance = NSAppearance(named: .vibrantDark)

        blur.material     = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state        = .active
        blur.wantsLayer   = true
        blur.layer?.cornerRadius  = 18
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth   = 0.5
        blur.layer?.borderColor   = NSColor.white.withAlphaComponent(0.15).cgColor
        contentView = blur

        iconRow.orientation = .horizontal
        iconRow.alignment   = .centerY
        iconRow.spacing     = kCellSpacing
        iconRow.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(iconRow)

        titleLabel.font                 = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor            = .white
        titleLabel.alignment            = .center
        titleLabel.lineBreakMode        = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isBezeled            = false
        titleLabel.drawsBackground      = false
        titleLabel.isEditable           = false
        titleLabel.isSelectable         = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(titleLabel)

        subtitleLabel.font                 = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor            = NSColor.white.withAlphaComponent(0.5)
        subtitleLabel.alignment            = .center
        subtitleLabel.lineBreakMode        = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.isBezeled            = false
        subtitleLabel.drawsBackground      = false
        subtitleLabel.isEditable           = false
        subtitleLabel.isSelectable         = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconRow.topAnchor.constraint(equalTo: blur.topAnchor, constant: kPad),
            iconRow.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            iconRow.heightAnchor.constraint(equalToConstant: kCellH),

            titleLabel.topAnchor.constraint(equalTo: iconRow.bottomAnchor, constant: kInfoGap),
            titleLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: kPad),
            titleLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -kPad),
            titleLabel.heightAnchor.constraint(equalToConstant: kTitleH),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: kTitleGap),
            subtitleLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: kPad),
            subtitleLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -kPad),
            subtitleLabel.heightAnchor.constraint(equalToConstant: kSubH),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(wins: [WinInfo], sel: Int) {
        self.wins = wins; selIdx = sel
        iconRow.arrangedSubviews.forEach { iconRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, w) in wins.enumerated() {
            let cell = IconCellView(win: w)
            cell.onPick = { [weak self] in self?.onPick?(i) }
            cell.setSelected(i == sel)
            iconRow.addArrangedSubview(cell)
        }
        if sel < wins.count { updateInfoLabels(for: wins[sel]) }
        refit(); orderFront(nil)
    }

    func move(_ delta: Int) {
        guard !wins.isEmpty else { return }
        let cells = iconRow.arrangedSubviews.compactMap { $0 as? IconCellView }
        if selIdx < cells.count { cells[selIdx].setSelected(false) }
        selIdx = (selIdx + delta + wins.count) % wins.count
        if selIdx < cells.count { cells[selIdx].setSelected(true) }
        if selIdx < wins.count  { updateInfoLabels(for: wins[selIdx]) }
    }

    func currentIndex() -> Int { selIdx }
    func hide() { orderOut(nil); wins = [] }

    private func updateInfoLabels(for win: WinInfo) {
        titleLabel.stringValue = win.title.isEmpty ? (win.app.localizedName ?? "") : win.title

        let appName = win.app.localizedName ?? ""
        let dimAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let s = NSMutableAttributedString(string: appName, attributes: dimAttr)

        if win.ax == nil || win.isMinimized {
            let tagColor  = win.ax == nil ? kOffSpaceAmber : kMinimizedPurple
            let tagText   = win.ax == nil ? "other space"  : "minimized"
            let sepAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.25),
            ]
            let tagAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: tagColor.withAlphaComponent(0.85),
            ]
            if !appName.isEmpty {
                s.append(NSAttributedString(string: "  ·  ", attributes: sepAttr))
            }
            s.append(NSAttributedString(string: tagText, attributes: tagAttr))
        }

        subtitleLabel.attributedStringValue = s
    }

    private func refit() {
        iconRow.layoutSubtreeIfNeeded()
        let n      = CGFloat(wins.count)
        let panelW = max(240, n * kCellW + max(n - 1, 0) * kCellSpacing + kPad * 2)
        let panelH = kPad + kCellH + kInfoGap + kTitleH + kTitleGap + kSubH + kPad
        setContentSize(NSSize(width: panelW, height: panelH))
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: vf.midX - panelW / 2,
                                   y: vf.midY - panelH / 2 + 60))
        }
    }
}

// MARK: - Switcher

class Switcher {
    private var wins    = [WinInfo]()
    private let overlay = Overlay()
    var isVisible       = false

    init() { overlay.onPick = { [weak self] i in self?.commit(i) } }

    func trigger(reverse: Bool) {
        guard let ws = windowsForFrontApp(), ws.count > 1 else { return }
        if !isVisible {
            wins = ws
            let cur  = focusedIndex(in: wins)
            let next = (cur + (reverse ? -1 : 1) + wins.count) % wins.count
            isVisible = true
            overlay.present(wins: wins, sel: next)
        } else {
            overlay.move(reverse ? -1 : 1)
        }
    }

    func move(_ delta: Int) { guard isVisible else { return }; overlay.move(delta) }
    func commitCurrent()    { guard isVisible else { return }; commit(overlay.currentIndex()) }
    func dismiss()          { isVisible = false; overlay.hide() }

    private func commit(_ idx: Int) {
        isVisible = false; overlay.hide()
        guard idx < wins.count else { return }
        let w = wins[idx]
        wlog("commit idx=\(idx) title='\(w.title)' cgId=\(w.cgId) hasAX=\(w.ax != nil)")

        if w.ax == nil && w.cgId != 0 {
            DispatchQueue.global().async {
                switchToWindowSpace(w.cgId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    focusWindow(cgId: w.cgId, pid: w.app.processIdentifier)
                    w.app.activate(options: [])
                }
            }
        } else if w.cgId != 0, let ax = w.ax {
            DispatchQueue.global().async {
                focusWindow(cgId: w.cgId, pid: w.app.processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                    w.app.activate(options: [])
                }
            }
        } else if let ax = w.ax {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            w.app.activate(options: [])
        } else {
            w.app.activate(options: [])
        }
    }
}

// MARK: - Hotkey monitor

class HotkeyMonitor {
    private var tap: CFMachPort?
    private let switcher = Switcher()
    private var frontAppMulti = false

    private var didPromptAX     = false
    private var didPromptListen = false

    func start() {
        wlog("start() AX=\(AXIsProcessTrusted()) Listen=\(CGPreflightListenEventAccess())")
        guard AXIsProcessTrusted() else {
            if !didPromptAX {
                didPromptAX = true
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
            return
        }
        guard CGPreflightListenEventAccess() else {
            if !didPromptListen {
                didPromptListen = true
                CGRequestListenEventAccess()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
            return
        }
        makeTap()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.updateCache(for: app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication { updateCache(for: front) }
    }

    private func updateCache(for app: NSRunningApplication) {
        let bid = app.bundleIdentifier
        let siblings = bid.map { b in NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == b && $0.activationPolicy == .regular }
        } ?? [app]
        var axCount = 0
        for sib in siblings {
            let axApp = AXUIElementCreateApplication(sib.processIdentifier)
            var v: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success {
                axCount += (v as? [AXUIElement])?.filter { classifyWindow($0) != .rejected }.count ?? 0
            }
        }
        frontAppMulti = axCount >= 2
        wlog("cache: \(app.localizedName ?? "?") axWins=\(axCount) multi=\(frontAppMulti)")
    }

    private func makeTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, ref in
                Unmanaged<HotkeyMonitor>.fromOpaque(ref!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            wlog("tapCreate nil — retry in 1s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.makeTap() }
            return
        }
        wlog("tap created ✓")
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            if !event.flags.contains(.maskCommand) && switcher.isVisible {
                DispatchQueue.main.async { self.switcher.commitCurrent() }
            }
            return Unmanaged.passRetained(event)
        }
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let cmd = event.flags.contains(.maskCommand)
        let sft = event.flags.contains(.maskShift)

        if key == 50 && cmd {   // Cmd+`
            if switcher.isVisible || frontAppMulti {
                DispatchQueue.main.async { self.switcher.trigger(reverse: sft) }
                return nil
            }
            // Cache stale — check properly async; pass through in the meantime
            DispatchQueue.main.async {
                if let ws = windowsForFrontApp(), ws.count > 1 {
                    self.frontAppMulti = true
                    self.switcher.trigger(reverse: sft)
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard switcher.isVisible else { return Unmanaged.passRetained(event) }
        switch key {
        case 53:  DispatchQueue.main.async { self.switcher.dismiss() };       return nil  // Esc
        case 36:  DispatchQueue.main.async { self.switcher.commitCurrent() }; return nil  // Return
        case 123, 126: DispatchQueue.main.async { self.switcher.move(-1) };   return nil  // ← ↑
        case 124, 125: DispatchQueue.main.async { self.switcher.move(1) };    return nil  // → ↓
        default: break
        }
        return Unmanaged.passRetained(event)
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = HotkeyMonitor()
    var statusItem: NSStatusItem?
    private var axItem:     NSMenuItem!
    private var listenItem: NSMenuItem!
    private var pollTimer:  Timer?

    func applicationDidFinishLaunching(_: Notification) {
        try? "--- WinSwitch started ---\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.2.layers.3d",
                                            accessibilityDescription: "WinSwitch")
        axItem     = NSMenuItem(title: "", action: #selector(openAccessibility),  keyEquivalent: "")
        listenItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
        axItem.target     = self
        listenItem.target = self

        let menu = NSMenu()
        menu.addItem(axItem)
        menu.addItem(listenItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WinSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu

        updatePermissionItems()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updatePermissionItems()
        }
        monitor.start()
    }

    private func updatePermissionItems() {
        let ax     = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        axItem.title     = (ax     ? "✓" : "✗") + " Accessibility"
        listenItem.title = (listen ? "✓" : "✗") + " Input Monitoring"
        axItem.isEnabled     = !ax
        listenItem.isEnabled = !listen
        // dim icon when permissions missing
        statusItem?.button?.alphaValue = (ax && listen) ? 1.0 : 0.5
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}

let app = NSApplication.shared
let del = AppDelegate()
app.delegate = del
app.run()
