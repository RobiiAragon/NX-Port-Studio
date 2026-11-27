import AppKit
import GameController

/// What a controller holds at one moment, reduced to the Library's keys.
struct LibraryPadState: Equatable {
    var direction: LibraryKey?
    var activate = false
    var alternate = false
    var back = false
    var fullScreen = false

    /// The direction of the directional pad or the left stick. The axis that is pushed
    /// further wins, and a stick must be pushed at least halfway, so a resting stick
    /// does not drift.
    static func direction(x: Float, y: Float, threshold: Float = 0.5) -> LibraryKey? {
        guard max(abs(x), abs(y)) >= threshold else { return nil }
        return abs(x) >= abs(y) ? (x < 0 ? .left : .right) : (y > 0 ? .up : .down)
    }
}

/// Turns successive controller states into Library keys. A button sends its key once when
/// it goes down. A direction sends once when it starts, then repeats while it is held,
/// as a held arrow key does: first after `delay`, then every `interval`.
struct LibraryPadRepeater {
    var delay: TimeInterval = 0.4
    var interval: TimeInterval = 0.12
    private var last = LibraryPadState()
    private var nextRepeat: TimeInterval = .infinity

    mutating func step(_ state: LibraryPadState, at now: TimeInterval) -> [LibraryKey] {
        var keys: [LibraryKey] = []
        if let direction = state.direction {
            if direction != last.direction {
                keys.append(direction); nextRepeat = now + delay
            } else if now >= nextRepeat {
                keys.append(direction); nextRepeat = now + interval
            }
        } else {
            nextRepeat = .infinity
        }
        if state.activate && !last.activate { keys.append(.activate) }
        if state.alternate && !last.alternate { keys.append(.alternate) }
        if state.back && !last.back { keys.append(.back) }
        if state.fullScreen && !last.fullScreen { keys.append(.fullScreen) }
        last = state
        return keys
    }
}

/// The symbols of the buttons the hint bar names, as the connected controller labels them
/// (`sfSymbolsName`: a cross on one controller, an A on another).
struct LibraryPadGlyphs: Equatable {
    var move = "dpad"
    var activate = "a.circle"
    var alternate = "x.circle"
    var back = "b.circle"
    var fullScreen = "line.3.horizontal.circle"
}

/// Game controllers on the Library. The system hands controller input to the frontmost
/// app only, so a port that is playing never moves Studio's focus, and Studio reads a
/// controller only while the Library is on screen. The face button the system calls A
/// opens, B goes back, X opens a port's settings window and Menu toggles full screen.
@MainActor
final class LibraryControllerInput {
    private let model: StudioModel
    private var repeater = LibraryPadRepeater()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(model: StudioModel) { self.model = model }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timer?.invalidate(); timer = nil
        model.libraryPadGlyphs = nil
    }

    private var gamepad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().lazy.compactMap(\.extendedGamepad).first
    }

    /// Polls only while a controller is connected; with none, nothing runs.
    private func update() {
        guard let pad = gamepad else {
            timer?.invalidate(); timer = nil
            model.libraryPadGlyphs = nil
            return
        }
        model.libraryPadGlyphs = LibraryPadGlyphs(
            move: pad.dpad.sfSymbolsName ?? "dpad",
            activate: pad.buttonA.sfSymbolsName ?? "a.circle",
            alternate: pad.buttonX.sfSymbolsName ?? "x.circle",
            back: pad.buttonB.sfSymbolsName ?? "b.circle",
            fullScreen: pad.buttonMenu.sfSymbolsName ?? "line.3.horizontal.circle")
        guard timer == nil else { return }
        repeater = LibraryPadRepeater()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard let pad = gamepad else { update(); return }
        // In the background the system stops sending this app the controller's input, and
        // the last values could stay held; start afresh when Studio comes back.
        guard NSApp.isActive else { repeater = LibraryPadRepeater(); return }
        let dpad = LibraryPadState.direction(x: pad.dpad.xAxis.value, y: pad.dpad.yAxis.value)
        let stick = LibraryPadState.direction(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value)
        let state = LibraryPadState(direction: dpad ?? stick, activate: pad.buttonA.isPressed, alternate: pad.buttonX.isPressed,
                                    back: pad.buttonB.isPressed, fullScreen: pad.buttonMenu.isPressed)
        for key in repeater.step(state, at: ProcessInfo.processInfo.systemUptime) { model.handleLibraryKey(key) }
    }
}
