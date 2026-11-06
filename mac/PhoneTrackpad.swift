// Phone Trackpad — Mac side.
// Receives raw finger positions (millimetres) from the Android app, recognises
// trackpad gestures and turns them into native macOS input events.

import Cocoa
import Network
import ServiceManagement

let port: UInt16 = 9876
let bonjourType = "_phonetrackpad._tcp"

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard
    /// Follows the Mac's own setting (System Settings → Mouse/Trackpad → Natural scrolling).
    static var natural: Bool {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
    }
    static var speed: Double {
        get { d.object(forKey: "trackingSpeed") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "trackingSpeed") }
    }
}

// MARK: - Event output

final class EventOut {
    private let src = CGEventSource(stateID: .hidSystemState)
    private(set) var pos = CGPoint.zero
    private var leftDown = false
    private var displays: [CGRect] = []
    private var scrollRest = (x: 0.0, y: 0.0)

    func syncPosition() {
        displays = Self.displayBounds()
        if !leftDown, let e = CGEvent(source: nil) { pos = e.location }
    }

    func move(dx: Double, dy: Double) {
        if dx == 0 && dy == 0 { return }
        let old = pos
        pos = clamp(CGPoint(x: pos.x + dx, y: pos.y + dy), from: old)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func press(_ button: CGMouseButton, down: Bool, clickState: Int64) {
        let type: CGEventType = switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (_, true): .rightMouseDown
        case (_, false): .rightMouseUp
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.post(tap: .cghidEventTap)
        if button == .left { leftDown = down }
    }

    func click(_ button: CGMouseButton, clickState: Int64) {
        press(button, down: true, clickState: clickState)
        press(button, down: false, clickState: clickState)
    }

    func releaseIfHeld() {
        if leftDown { press(.left, down: false, clickState: 1) }
    }

    /// dx/dy are content offsets in pixels: positive reveals content above / to the left.
    /// phase: 1 began, 2 changed, 4 ended. momentum: 1 begin, 2 continue, 3 end.
    func scroll(dx: Double, dy: Double, phase: Int64, momentum: Int64) {
        scrollRest.x += dx
        scrollRest.y += dy
        let ix = scrollRest.x.rounded(.towardZero), iy = scrollRest.y.rounded(.towardZero)
        scrollRest.x -= ix
        scrollRest.y -= iy
        if phase == 4 || momentum == 3 { scrollRest = (0, 0) }
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.post(tap: .cghidEventTap)
    }

    /// Pinch goes out as private gesture events (CGS type 29), which apps receive as
    /// real magnify(with:) events. hidType 61 = gesture started, 62 = ended, 8 = zoom.
    func gesture(_ hidType: Int64) {
        gestureEvent(hidType)?.post(tap: .cghidEventTap)
    }

    /// phase: 1 began, 2 changed, 4 ended.
    func zoom(_ magnification: Double, phase: Int64) {
        guard let e = gestureEvent(8) else { return }
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        e.post(tap: .cghidEventTap)
    }

    private func gestureEvent(_ hidType: Int64) -> CGEvent? {
        guard let e = CGEvent(source: src), let type = CGEventType(rawValue: 29) else { return nil }
        e.type = type
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: hidType)
        return e
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let held: (code: CGKeyCode, flag: CGEventFlags)? = flags.contains(.maskControl) ? (59, .maskControl)
            : flags.contains(.maskCommand) ? (55, .maskCommand) : nil
        if let held { modifier(held.code, down: true, flags: held.flag) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        if let held { modifier(held.code, down: false, flags: []) }
        // Otherwise macOS keeps Control/Fn "held" after a synthetic shortcut, and every later
        // tap arrives as a Control-click (a right click) until a real mouse click resets it.
        if let e = CGEvent(source: src) {
            e.type = .flagsChanged
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
    }

    private func modifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func clamp(_ p: CGPoint, from old: CGPoint) -> CGPoint {
        if displays.isEmpty { displays = Self.displayBounds() }
        if displays.contains(where: { $0.contains(p) }) { return p }
        guard let home = displays.first(where: { $0.contains(old) }) ?? displays.first else { return p }
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

// MARK: - Gesture engine

struct Touch { let id: Int; let p: CGPoint }   // millimetres on the phone

enum SwipeAction { case left, right, up, down, pinch, spread }

/// What the pointer badge should show for the two-finger Back/Forward gesture.
enum NavFeedback {
    case armed
    case progress(Double)      // -1 (Back) ... 1 (Forward)
    case fired(back: Bool)
    case ended
}

final class GestureEngine {
    var haptic: () -> Void = {}
    var navFeedback: (NavFeedback) -> Void = { _ in }
    private let out = EventOut()
    private let queue: DispatchQueue

    // Tunables (time in ms, distance in mm).
    private let tapMaxMs = 230.0
    private let tapMaxTravel = 2.0
    private let tapDragWindowMs = 300.0          // tap, then touch again within this to grab
    private let dragGraceMs = 400                // a drag survives a lift this short (to re-grip)
    private let navHoldMs = 500                  // two fingers held this long arm Back/Forward
    private let navHoldSlop = 3.0                // moving further than this during the hold cancels it
    private let navSwipeTravel = 10.0            // drag this far sideways after the hold to navigate
    private let pinchStartSpread = 2.0
    private let pinchScale = 50.0                // mm of finger spread per 1.0 magnification
    private let scrollStartTravel = 0.8
    private let swipeTravel = 14.0
    private let pinchTravel = 9.0

    private var prevCount = 0
    private var sessionStart = 0.0
    private var maxCount = 0
    private var travel = 0.0
    private var starts: [Int: CGPoint] = [:]
    private var lastT = 0.0
    private var lastCentroid = CGPoint.zero
    private var baseCentroid = CGPoint.zero
    private var baseRadius = 0.0
    private var speed = 0.0                      // smoothed finger speed, mm/s
    private var lifting = false                  // fingers are leaving a multi-finger gesture
    private var fired = false                    // a 3/4-finger or Back/Forward action already ran this touch
    private var navHoldWork: DispatchWorkItem?
    private var navArmed = false                 // two-finger hold finished: a sideways drag navigates
    private var navBase = CGPoint.zero
    private var overlay: SwipeAction?            // Mission Control (.up) or App Exposé (.down) we opened
    private var tapDragArmed = false             // second touch shortly after a tap
    private var dragging = false
    private var continuingDrag = false           // this touch picked up a drag left held by the last one
    private var releaseWork: DispatchWorkItem?
    private var lastTapEnd = -1e9
    private var pendingClick: DispatchWorkItem?  // a tap's click, held back in case a second touch turns it into a drag
    private var secondFingerDelay = 0.0          // ms from the first finger landing to the second
    private let rightClickLandMs = 150.0         // two-finger tap only if both fingers land this close together
    private var pinching = false
    private var lastSpan = 0.0

    private var scrolling = false
    private var scrollSamples: [(t: Double, x: Double, y: Double)] = []
    private var momentum: DispatchSourceTimer?

    init(queue: DispatchQueue) { self.queue = queue }

    func frame(t: Double, touches: [Touch]) {
        let n = touches.count
        if n > 0 && prevCount == 0 { begin(t, touches) }
        if n == 0 {
            if prevCount > 0 { end(t) }
            prevCount = 0
            return
        }
        for tc in touches {
            if let s = starts[tc.id] {
                travel = max(travel, hypot(tc.p.x - s.x, tc.p.y - s.y))
            } else {
                starts[tc.id] = tc.p
            }
        }
        if n >= 2 && maxCount < 2 { secondFingerDelay = t - sessionStart }
        maxCount = max(maxCount, n)
        let c = centroid(touches)

        if n != prevCount {
            if scrolling { endScroll(t: t) }
            if pinching { endPinch() }
            if n > 1 && dragging { releaseDrag() }
            if n < prevCount && !dragging { lifting = true }
            if n > prevCount { lifting = false }
            if n > 1 { tapDragArmed = false }
            prevCount = n
            baseCentroid = c
            lastCentroid = c
            baseRadius = radius(touches, c)
            lastT = t
            speed = 0
            disarmNav()
            if n == 2 && !lifting {
                let work = DispatchWorkItem { [weak self] in self?.navHoldElapsed() }
                navHoldWork = work
                queue.asyncAfter(deadline: .now() + .milliseconds(navHoldMs), execute: work)
            }
            return
        }

        let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
        let dt = max(t - lastT, 1)
        lastCentroid = c
        lastT = t
        speed = speed * 0.6 + hypot(dx, dy) / dt * 1000 * 0.4
        if lifting { return }

        switch n {
        case 1: pointer(dx, dy)
        case 2: twoFinger(t, dx, dy, c, touches)
        case 3, 4: swipe(n, c, touches)
        default: break
        }
    }

    /// Connection dropped: let go of anything held.
    func reset() {
        stopMomentum(sendEnd: true)
        if scrolling { scrolling = false; out.scroll(dx: 0, dy: 0, phase: 4, momentum: 0) }
        if pinching { endPinch() }
        disarmNav()
        pendingClick?.cancel()
        pendingClick = nil
        releaseWork?.cancel()
        releaseWork = nil
        dragging = false
        out.releaseIfHeld()
        prevCount = 0
        lastTapEnd = -1e9
    }

    // MARK: Session

    private func begin(_ t: Double, _ touches: [Touch]) {
        stopMomentum(sendEnd: true)
        continuingDrag = releaseWork != nil
        releaseWork?.cancel()
        releaseWork = nil
        out.syncPosition()
        sessionStart = t
        maxCount = 0
        travel = 0
        starts = [:]
        lifting = false
        fired = false
        scrolling = false
        pinching = false
        secondFingerDelay = 0
        let hadPendingClick = pendingClick != nil
        pendingClick?.cancel()
        pendingClick = nil
        tapDragArmed = hadPendingClick && !continuingDrag && touches.count == 1 && t - lastTapEnd < tapDragWindowMs
        if tapDragArmed {
            // Tap, then touch again: the held-back click becomes this one press, so apps that
            // time double clicks themselves (Figma) see a single press and a drag.
            out.press(.left, down: true, clickState: 1)
            dragging = true
        } else if hadPendingClick {
            out.click(.left, clickState: 1)
        }
    }

    private func releaseDrag() {
        releaseWork?.cancel()
        releaseWork = nil
        out.press(.left, down: false, clickState: 1)
        dragging = false
    }

    private func end(_ t: Double) {
        disarmNav()
        let quick = t - sessionStart < tapMaxMs && travel < tapMaxTravel
        let isTap = quick && !fired && !scrolling && !dragging && !pinching
        if isTap || dragging { overlay = nil }   // a click picks a window, which closes the overlay
        if scrolling { endScroll(t: t) }
        if pinching { endPinch() }
        if dragging && tapDragArmed && travel < tapMaxTravel && maxCount == 1 {
            // Second touch lifted without dragging (however long it was held): the release
            // completes the first click, then the second click makes it a double click.
            releaseDrag()
            out.click(.left, clickState: 2)
            haptic()
            lastTapEnd = -1e9
        } else if dragging {
            if continuingDrag && quick {
                releaseDrag()                     // a tap drops a drag that was being held
            } else {
                let work = DispatchWorkItem { [weak self] in self?.releaseDrag() }
                releaseWork = work
                queue.asyncAfter(deadline: .now() + .milliseconds(dragGraceMs), execute: work)
            }
            lastTapEnd = -1e9
        } else if isTap && maxCount == 1 {
            // Hold the click back for the tap-drag window, like a real trackpad.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.out.click(.left, clickState: 1)
            }
            pendingClick = work
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(tapDragWindowMs) + 30), execute: work)
            lastTapEnd = t
            haptic()
        } else if isTap && maxCount == 2 && secondFingerDelay <= rightClickLandMs {
            out.click(.right, clickState: 1)
            haptic()
            lastTapEnd = -1e9
        } else {
            lastTapEnd = -1e9
        }
        tapDragArmed = false
    }

    // MARK: One finger: pointer, tap-and-drag

    private func pointer(_ dx: Double, _ dy: Double) {
        let x = min(speed / 200, 1)
        let gain = Prefs.speed * (2.6 + 13 * x * x * (3 - 2 * x))
        out.move(dx: dx * gain, dy: dy * gain)
    }

    // MARK: Two fingers: scroll with momentum, or pinch to zoom

    private func twoFinger(_ t: Double, _ dx: Double, _ dy: Double, _ c: CGPoint, _ touches: [Touch]) {
        if navArmed { navigate(c); return }
        let span = radius(touches, c) * 2
        let mx = c.x - baseCentroid.x, my = c.y - baseCentroid.y
        let move = hypot(mx, my), spread = abs(span - baseRadius * 2)
        // The hold runs alongside scrolling and pinching, which never wait for it.
        if move > navHoldSlop || spread > navHoldSlop { navHoldWork?.cancel() }
        if pinching { emitPinch(span, phase: 2); return }
        if scrolling { emitScroll(t, dx, dy, phase: 2); return }
        if spread > pinchStartSpread && spread > move * 1.5 {
            pinching = true
            lastSpan = baseRadius * 2
            out.gesture(61)
            emitPinch(span, phase: 1)
        } else if move > scrollStartTravel && move >= spread {
            scrolling = true
            scrollSamples.removeAll()
            emitScroll(t, mx, my, phase: 1)
        }
    }

    private func emitPinch(_ span: Double, phase: Int64) {
        out.zoom((span - lastSpan) / pinchScale, phase: phase)
        lastSpan = span
    }

    /// Two fingers stayed put for the whole hold. Finger drift may have started a tiny scroll or
    /// pinch, so stop that, then wait for the sideways drag.
    private func navHoldElapsed() {
        guard prevCount == 2, !lifting else { return }
        if scrolling {
            scrolling = false
            out.scroll(dx: 0, dy: 0, phase: 4, momentum: 0)
        }
        if pinching { endPinch() }
        navArmed = true
        navBase = lastCentroid
        haptic()
        navFeedback(.armed)
    }

    private func disarmNav() {
        navHoldWork?.cancel()
        if navArmed { navFeedback(.ended) }
        navArmed = false
    }

    private func navigate(_ c: CGPoint) {
        guard !fired else { return }
        let dx = c.x - navBase.x, dy = c.y - navBase.y
        let sideways = abs(dx) > abs(dy) * 1.5
        guard abs(dx) > navSwipeTravel, sideways else {
            navFeedback(.progress(sideways ? -dx / navSwipeTravel : 0))
            return
        }
        fired = true
        out.key(dx > 0 ? 33 : 30, flags: [.maskCommand])   // drag right ⌘[ Back, drag left ⌘] Forward
        haptic()
        navFeedback(.fired(back: dx > 0))
    }

    private func endPinch() {
        pinching = false
        out.zoom(0, phase: 4)
        out.gesture(62)
    }

    private func emitScroll(_ t: Double, _ dxmm: Double, _ dymm: Double, phase: Int64) {
        let gain = 7.0 * (1 + min(speed, 300) / 150)
        let sign = Prefs.natural ? 1.0 : -1.0
        // No axis lock: apps that want straight scrolling (NSScrollView, browsers) apply their own.
        let px = dxmm * gain * sign
        let py = dymm * gain * sign
        scrollSamples.append((t, px, py))
        scrollSamples.removeAll { t - $0.t > 100 }
        out.scroll(dx: px, dy: py, phase: phase, momentum: 0)
    }

    private func endScroll(t: Double) {
        scrolling = false
        out.scroll(dx: 0, dy: 0, phase: 4, momentum: 0)
        let recent = scrollSamples.filter { t - $0.t <= 80 }
        guard recent.count >= 3, let first = recent.first, let last = recent.last else { return }
        let span = max(last.t - first.t, 8)
        let vx = recent.dropFirst().reduce(0) { $0 + $1.x } / span * 1000
        let vy = recent.dropFirst().reduce(0) { $0 + $1.y } / span * 1000
        if hypot(vx, vy) > 150 { startMomentum(vx, vy) }
    }

    private func startMomentum(_ vx: Double, _ vy: Double) {
        stopMomentum(sendEnd: false)
        var v = (x: vx, y: vy)
        var first = true
        let tick = 1.0 / 120
        let decay = pow(0.9972, tick * 1000)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.out.scroll(dx: v.x * tick, dy: v.y * tick, phase: 0, momentum: first ? 1 : 2)
            first = false
            v.x *= decay
            v.y *= decay
            if hypot(v.x, v.y) < 20 { self.stopMomentum(sendEnd: true) }
        }
        momentum = timer
        timer.resume()
    }

    private func stopMomentum(sendEnd: Bool) {
        guard let m = momentum else { return }
        m.cancel()
        momentum = nil
        if sendEnd { out.scroll(dx: 0, dy: 0, phase: 0, momentum: 3) }
    }

    // MARK: Three / four fingers

    private func swipe(_ n: Int, _ c: CGPoint, _ touches: [Touch]) {
        guard !fired else { return }
        let dx = c.x - baseCentroid.x, dy = c.y - baseCentroid.y
        if n == 4 {
            let dr = radius(touches, c) - baseRadius
            if abs(dr) > pinchTravel && abs(dr) > hypot(dx, dy) {
                fire(dr > 0 ? .spread : .pinch)
                return
            }
        }
        guard hypot(dx, dy) > swipeTravel else { return }
        if abs(dx) > abs(dy) { fire(dx < 0 ? .left : .right) } else { fire(dy < 0 ? .up : .down) }
    }

    private func fire(_ action: SwipeAction) {
        fired = true
        let ctrlArrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        // Like a real trackpad, the opposite swipe closes Mission Control / App Exposé.
        if (overlay == .up && action == .down) || (overlay == .down && action == .up) {
            overlay = nil
            out.key(53, flags: [])   // Escape
            haptic()
            return
        }
        overlay = action == .up || action == .down ? action : nil
        switch action {
        case .left: out.key(124, flags: ctrlArrow)   // next Space / full-screen app
        case .right: out.key(123, flags: ctrlArrow)  // previous Space
        case .up: out.key(126, flags: ctrlArrow)     // Mission Control
        case .down: out.key(125, flags: ctrlArrow)   // App Exposé
        case .spread: out.key(103, flags: [.maskSecondaryFn])  // F11: Show Desktop
        case .pinch:
            DispatchQueue.main.async {
                let apps = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
                if let path = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        haptic()
    }

    private func centroid(_ ts: [Touch]) -> CGPoint {
        let n = Double(ts.count)
        return CGPoint(x: ts.reduce(0) { $0 + $1.p.x } / n, y: ts.reduce(0) { $0 + $1.p.y } / n)
    }

    private func radius(_ ts: [Touch], _ c: CGPoint) -> Double {
        ts.reduce(0) { $0 + hypot($1.p.x - c.x, $1.p.y - c.y) } / Double(ts.count)
    }
}

// MARK: - Network

/// Phones the user approved: phone id → its secret and name.
enum Pairing {
    private static let key = "pairedPhones"
    static var phones: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func isTrusted(_ id: String, secret: String) -> Bool { phones[id]?["secret"] == secret }
    static func trust(_ id: String, secret: String, name: String) { phones[id] = ["secret": secret, "name": name] }
    static func forgetAll() { phones = [:] }
}

/// One phone connection. Only the paired phone that is `active` gets to move the pointer.
final class Client {
    let conn: NWConnection
    var buffer = Data()
    var phoneId: String?
    var name = "Phone"
    init(_ conn: NWConnection) { self.conn = conn }
    func send(_ line: String) { conn.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in }) }

    /// Send a last message, then hang up once it has gone out.
    func refuse(_ line: String) {
        conn.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}

final class Server {
    let queue = DispatchQueue(label: "trackpad.engine", qos: .userInteractive)
    lazy var engine = GestureEngine(queue: queue)
    var onStatus: (String?) -> Void = { _ in }       // phone name, or nil when disconnected
    var onNav: (NavFeedback) -> Void = { _ in }
    /// Asks the user whether a new phone may connect (main thread); reply through `answer`.
    var askToPair: (_ phone: String, _ code: String, _ answer: @escaping (Bool) -> Void) -> Void = { _, _, answer in answer(false) }
    private var listener: NWListener?
    private var clients: [Client] = []
    private var active: Client?                  // the paired phone in use
    private var pairing: Client?                 // waiting for the user's answer
    private var peerIP: String?                  // UDP frames are only taken from the active phone
    private var lastSeq = -1
    private var udpSource: DispatchSourceRead?
    private let macName = Host.current().localizedName ?? "Mac"

    func start() {
        engine.haptic = { [weak self] in self?.send("V") }
        engine.navFeedback = { [weak self] f in DispatchQueue.main.async { self?.onNav(f) } }
        if udpSource == nil { startUDP() }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.service = NWListener.Service(name: macName, type: bonjourType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed = st {
                self?.listener?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.start() }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func send(_ line: String) { active?.send(line) }

    func sendNatural() { queue.async { self.send("N \(Prefs.natural ? 1 : 0)") } }

    /// After "Forget Paired Phones": drop every connection so phones must be approved again.
    func disconnectAll() { queue.async { self.clients.forEach { $0.conn.cancel() } } }

    private func accept(_ c: NWConnection) {
        let client = Client(c)
        clients.append(client)
        c.stateUpdateHandler = { [weak self, weak client] st in
            guard let self, let client else { return }
            switch st {
            case .failed, .cancelled: self.closed(client)
            default: break
            }
        }
        c.start(queue: queue)
        receive(client)
    }

    private func closed(_ client: Client) {
        clients.removeAll { $0 === client }
        if pairing === client { pairing = nil }
        guard active === client else { return }
        active = nil
        peerIP = nil
        engine.reset()
        DispatchQueue.main.async { self.onStatus(nil) }
    }

    private func receive(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, self.clients.contains(where: { $0 === client }) else { return }
            if let data { client.buffer.append(data); self.drain(client) }
            if done || err != nil { client.conn.cancel(); return }
            self.receive(client)
        }
    }

    private func drain(_ client: Client) {
        while let nl = client.buffer.firstIndex(of: 10) {
            let line = String(decoding: client.buffer[client.buffer.startIndex..<nl], as: UTF8.self)
            client.buffer.removeSubrange(client.buffer.startIndex...nl)
            handle(line, from: client)
        }
    }

    private func handle(_ line: String, from client: Client) {
        let parts = line.split(separator: " ")
        guard let cmd = parts.first else { return }
        switch cmd {
        case "T":
            if client === active { touchFrame(parts) }
        case "A":   // A <phone id> <secret> <name…>
            guard client.phoneId == nil, parts.count >= 3 else { return }
            let id = String(parts[1]), secret = String(parts[2])
            client.phoneId = id
            if parts.count > 3 { client.name = parts.dropFirst(3).joined(separator: " ") }
            if Pairing.isTrusted(id, secret: secret) { authorize(client) } else { requestPairing(client, secret: secret) }
        default: break   // "P" keep-alive
        }
    }

    /// T <seq> <ms> <count> (<id> <xmm> <ymm>)*, over UDP and/or TCP.
    private func touchFrame(_ parts: [Substring]) {
        guard parts.count >= 4, let seq = Int(parts[1]), let t = Double(parts[2]), let n = Int(parts[3]),
              parts.count >= 4 + n * 3 else { return }
        guard seq > lastSeq else { return }   // late or duplicate
        lastSeq = seq
        var touches: [Touch] = []
        touches.reserveCapacity(n)
        for i in 0..<n {
            let b = 4 + i * 3
            if let id = Int(parts[b]), let x = Double(parts[b + 1]), let y = Double(parts[b + 2]) {
                touches.append(Touch(id: id, p: CGPoint(x: x, y: y)))
            }
        }
        engine.frame(t: t, touches: touches)
    }

    private func authorize(_ client: Client) {
        if let current = active, current !== client {
            guard current.phoneId == client.phoneId else {   // another phone is in use
                client.refuse("B")
                return
            }
            closed(current)                                 // same phone reconnecting: the old link is stale
            current.conn.cancel()
        }
        active = client
        peerIP = Self.ipv4(of: client.conn.endpoint)
        lastSeq = -1
        engine.reset()
        client.send("M \(macName)")
        client.send("N \(Prefs.natural ? 1 : 0)")
        client.send("OK")
        let name = client.name
        DispatchQueue.main.async { self.onStatus(name) }
    }

    /// A phone this Mac hasn't approved: show the same code on both screens and ask the user.
    private func requestPairing(_ client: Client, secret: String) {
        guard pairing == nil else {
            client.refuse("B")
            return
        }
        pairing = client
        let code = String(format: "%04d", Int.random(in: 0...9999))
        client.send("M \(macName)")
        client.send("C \(code)")
        let name = client.name
        DispatchQueue.main.async {
            self.askToPair(name, code) { allowed in
                self.queue.async {
                    guard self.pairing === client, let id = client.phoneId else { return }   // phone left meanwhile
                    self.pairing = nil
                    if allowed {
                        Pairing.trust(id, secret: secret, name: name)
                        self.authorize(client)
                    } else {
                        client.refuse("D")
                    }
                }
            }
        }
    }

    // UDP: each datagram is one touch frame line.

    private func startUDP() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readUDP(fd) }
        src.resume()
        udpSource = src
    }

    private func readUDP(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, $0, &len) }
            }
            guard n > 0 else { return }
            guard let peerIP, String(cString: inet_ntoa(from.sin_addr)) == peerIP else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.first == "T" { touchFrame(parts) }
            }
        }
    }

    private static func ipv4(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return a.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let a): return a.asIPv4.map { $0.rawValue.map(String.init).joined(separator: ".") }
        default: return nil
        }
    }
}

// MARK: - USB: keep `adb reverse` set up so the phone can reach 127.0.0.1

final class AdbBridge {
    private let adb: String? = [
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    func refresh() {
        guard let adb else { return }
        DispatchQueue.global(qos: .utility).async {
            let serials = Self.serials(adb)
                .filter { !$0.contains("._adb-tls-connect") && !$0.contains(":") }   // cable only; wireless adb is slower than direct Wi-Fi
            for s in serials { _ = Self.run(adb, ["-s", s, "reverse", "tcp:\(port)", "tcp:\(port)"]) }
        }
    }

    // ColorOS three-finger gestures (split screen, screenshots) cancel the phone app's touches.
    // The phone can't grant itself the permission to change them, so pause them over adb while
    // the phone app is connected and put the user's values back when it leaves.
    private let gestureKeys = [
        ("secure", "double_finger_split_screen_enable"),                  // 3-finger swipe up
        ("system", "oplus_customize_smart_apperceive_screen_capture"),    // 3-finger swipe down
        ("system", "oplus_customize_screenshot_enable_area_screenshot"),  // 3-finger hold
    ]
    private let gestureQueue = DispatchQueue(label: "trackpad.adb.gestures")

    func setPhoneGestures(paused: Bool) {
        guard let adb else { return }
        gestureQueue.async {
            let d = UserDefaults.standard
            // One record for the phone: adb names the same phone differently over USB and Wi-Fi.
            let saveKey = "savedPhoneGestures"
            for s in Self.serials(adb) {
                if paused {
                    let script = self.gestureKeys.map { "settings get \($0.0) \($0.1)" }.joined(separator: "; ")
                    let values = Self.run(adb, ["-s", s, "shell", script]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard values.count == self.gestureKeys.count else { continue }
                    var saved = d.dictionary(forKey: saveKey) as? [String: String] ?? [:]
                    var puts: [String] = []
                    // Only touch gestures that are on, and remember only what we switched off,
                    // so a gesture the user keeps off is never "restored" to on (or vice versa).
                    for (i, (ns, key)) in self.gestureKeys.enumerated() where values[i] != "null" && values[i] != "0" {
                        if saved[key] == nil { saved[key] = values[i] }
                        puts.append("settings put \(ns) \(key) 0")
                    }
                    guard !puts.isEmpty else { continue }   // already paused, or not a ColorOS phone
                    d.set(saved, forKey: saveKey)
                    _ = Self.run(adb, ["-s", s, "shell", puts.joined(separator: "; ")])
                } else {
                    guard let saved = d.dictionary(forKey: saveKey) as? [String: String] else { continue }
                    // Skip devices without these settings (an emulator) or that adb can't reach.
                    let script = self.gestureKeys.map { "settings get \($0.0) \($0.1)" }.joined(separator: "; ")
                    func read() -> [String] {
                        Self.run(adb, ["-s", s, "shell", script]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    let before = read()
                    guard before.count == self.gestureKeys.count, before.contains(where: { $0 != "null" }) else { continue }
                    let puts = self.gestureKeys.compactMap { ns, key in saved[key].map { "settings put \(ns) \(key) \($0)" } }
                    _ = Self.run(adb, ["-s", s, "shell", puts.joined(separator: "; ")])
                    // Keep the record until the phone confirms it, so a wireless debugging drop
                    // can't leave its gestures off for good. The retry timer tries again.
                    let after = read()
                    let restored = after.count == self.gestureKeys.count
                        && self.gestureKeys.enumerated().allSatisfy { i, k in saved[k.1].map { $0 == after[i] } ?? true }
                    if restored { d.removeObject(forKey: saveKey) }
                }
            }
        }
    }

    private static func serials(_ adb: String) -> [String] {
        run(adb, ["devices"]).split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: "\t")
            return cols.count == 2 && cols[1] == "device" ? String(cols[0]) : nil
        }
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Pointer badge for Back/Forward

/// A background app can't change the pointer icon, so this small panel follows the pointer instead.
final class NavBadge {
    private let size = NSSize(width: 84, height: 40)
    private let panel: NSPanel
    private let back = NSImageView()
    private let forward = NSImageView()
    private var follow: Timer?
    private var finished = false
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        panel.contentView = bg
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        for (view, symbol, name, x) in [(back, "arrow.left", "Back", 12.0), (forward, "arrow.right", "Forward", 48.0)] {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(config)
            view.frame = NSRect(x: x, y: 8, width: 24, height: 24)
            bg.addSubview(view)
        }
    }

    func show(_ feedback: NavFeedback) {
        switch feedback {
        case .armed:
            generation += 1
            finished = false
            highlight(0)
            panel.alphaValue = 1
            place()
            panel.orderFrontRegardless()
            follow?.invalidate()
            follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.place() }
        case .progress(let amount):
            if !finished { highlight(amount) }
        case .fired(let goBack):
            finished = true
            highlight(goBack ? -1 : 1)
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                if self?.generation == current { self?.hide() }
            }
        case .ended:
            if !finished { hide() }
        }
    }

    private func hide() {
        follow?.invalidate()
        follow = nil
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.generation == current { self?.panel.orderOut(nil) }
        })
    }

    /// -1 lights up Back, 1 lights up Forward, 0 shows both as ready.
    private func highlight(_ amount: Double) {
        let strength = min(abs(amount), 1)
        let (active, other) = amount < 0 ? (back, forward) : (forward, back)
        active.contentTintColor = strength > 0.1 ? .controlAccentColor : .white
        active.alphaValue = 0.7 + 0.3 * strength
        other.contentTintColor = .white
        other.alphaValue = 0.7 - 0.45 * strength
    }

    /// Just below and to the right of the pointer, kept on screen.
    private func place() {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(p) }?.visibleFrame ?? .zero
        let x = min(max(p.x + 16, screen.minX), screen.maxX - size.width)
        let y = min(max(p.y - 20 - size.height, screen.minY), screen.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let server = Server()
    private let navBadge = NavBadge()
    private let adb = AdbBridge()
    private var item: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Waiting for phone…", action: nil, keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Allow in Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
    private let naturalItem = NSMenuItem(title: "Natural scrolling (set in Mouse settings)", action: #selector(openMouseSettings), keyEquivalent: "")
    private var lastNatural = Prefs.natural
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let lagFixItem = NSMenuItem(title: "", action: #selector(toggleLagFix), keyEquivalent: "")
    private let forgetItem = NSMenuItem(title: "", action: #selector(forgetPhones), keyEquivalent: "")
    private let speeds: [(String, Double)] = [("Slow", 0.6), ("Medium", 1.0), ("Fast", 1.4), ("Very fast", 1.9)]
    private var speedItems: [NSMenuItem] = []
    private var connectedName: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false   // so "No Paired Phones" can show as disabled
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(naturalItem)
        let speedMenu = NSMenu()
        for (i, s) in speeds.enumerated() {
            let mi = NSMenuItem(title: s.0, action: #selector(pickSpeed(_:)), keyEquivalent: "")
            mi.tag = i
            mi.target = self
            speedMenu.addItem(mi)
            speedItems.append(mi)
        }
        let speedRoot = NSMenuItem(title: "Tracking speed", action: nil, keyEquivalent: "")
        speedRoot.submenu = speedMenu
        menu.addItem(speedRoot)
        menu.addItem(.separator())
        menu.addItem(forgetItem)
        menu.addItem(lagFixItem)
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Phone Trackpad", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        for mi in [accessItem, naturalItem, forgetItem, lagFixItem, loginItem] { mi.target = self }
        item.menu = menu

        server.onNav = { [weak self] in self?.navBadge.show($0) }
        server.askToPair = { phone, code, answer in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow “\(phone)” to control this Mac?"
            alert.informativeText = "Code: \(code)\n\nAllow only if your phone shows this same code. The phone can then move the pointer, click and scroll on this Mac."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
        server.onStatus = { [weak self] name in
            guard let self else { return }
            self.connectedName = name
            self.refreshIcon()
            self.adb.setPhoneGestures(paused: name != nil)
        }
        adb.setPhoneGestures(paused: false)   // undo anything left paused by a crash
        // While connected, re-check now and then: if wireless debugging came back late or
        // something switched the phone's gestures on again, pause them again.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.connectedName != nil else { return }
            self.adb.setPhoneGestures(paused: true)
        }
        server.start()
        refreshIcon()
        refreshMenu()

        adb.refresh()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, self.connectedName == nil else { return }
            self.adb.refresh()
            self.adb.setPhoneGestures(paused: false)   // retries a restore that didn't get through
        }
        // Pass changes to the Mac's natural scrolling setting on to the phone's switch.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Prefs.natural != self.lastNatural else { return }
            self.lastNatural = Prefs.natural
            self.server.sendNatural()
            self.refreshMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshIcon() {
        let symbol = connectedName == nil ? "hand.point.up.left" : "hand.point.up.left.fill"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Phone Trackpad")
        statusLine.title = connectedName.map { "Connected: \($0)" } ?? "Waiting for phone… (USB or Wi-Fi)"
    }

    private func refreshMenu() {
        accessItem.isHidden = AXIsProcessTrusted()
        naturalItem.state = Prefs.natural ? .on : .off
        let current = Prefs.speed
        for (i, mi) in speedItems.enumerated() { mi.state = abs(speeds[i].1 - current) < 0.01 ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let paired = Pairing.phones.count
        forgetItem.title = paired == 0 ? "No Paired Phones" : "Forget Paired Phones (\(paired))…"
        forgetItem.isEnabled = paired > 0
        lagFixItem.title = LagFix.installed ? "Uninstall Wi-Fi Lag Fix…" : "Install Wi-Fi Lag Fix (AWDL off while connected)…"
    }

    @objc private func openMouseSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Mouse-Settings.extension")!)
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        Prefs.speed = speeds[sender.tag].1
        refreshMenu()
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        refreshMenu()
    }

    @objc private func forgetPhones() {
        let names = Pairing.phones.values.compactMap { $0["name"] }.sorted().joined(separator: ", ")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget paired phones?"
        alert.informativeText = "\(names) will have to be allowed again before it can control this Mac."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Pairing.forgetAll()
        server.disconnectAll()
        refreshMenu()
    }

    @objc private func toggleLagFix() {
        if LagFix.installed { LagFix.uninstall() } else { LagFix.install() }
        refreshMenu()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Wi-Fi lag fix (root launchd service, see awdl-guard.sh)

enum LagFix {
    static let label = "com.phonetrackpad.awdlguard"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let supportDir = "/Library/Application Support/PhoneTrackpad"
    static let flag = "/var/run/phonetrackpad-awdl-off"

    static var installed: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Copies the script into a root-owned folder (so it can't be changed without admin
    /// rights) and registers it to run at boot.
    static func install() {
        guard let res = Bundle.main.resourcePath else { return }
        runAsAdmin([
            "mkdir -p \(q(supportDir))",
            "install -o root -g wheel -m 755 \(q(res + "/awdl-guard.sh")) \(q(supportDir + "/awdl-guard.sh"))",
            "install -o root -g wheel -m 644 \(q(res + "/\(label).plist")) \(q(plistPath))",
            "launchctl bootstrap system \(q(plistPath))",
        ].joined(separator: " && "))
    }

    static func uninstall() {
        runAsAdmin([
            "launchctl bootout system/\(label)",
            "rm -f \(q(plistPath))",
            "rm -rf \(q(supportDir))",
            "if [ -f \(flag) ]; then ifconfig awdl0 up; rm -f \(flag); fi",
        ].joined(separator: "; "))
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ shell: String) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Phone Trackpad needs your password to change the Wi-Fi lag fix.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
