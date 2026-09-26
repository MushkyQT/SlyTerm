import AppKit
import CMultitouch

// Private MultitouchSupport, dlopen'd so a missing symbol means "unavailable", not a crash.
// It only observes touches: system gestures such as three-finger "Look up" still fire.
final class TrackpadTapDetector {
    static let shared = TrackpadTapDetector()

    var onTap: (() -> Void)?
    var fingers = 3
    var alignTolerance: Float = 0.50

    private(set) var unavailableReason: String?
    private(set) var isRunning = false

    private let maxDuration = 0.35
    private let maxMovement: Float = 0.05
    private let minFingerGap: Float = 0.04
    private let debounce = 0.5

    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallbackFunction?) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    private var startFn: StartFn?
    private var stopFn: StopFn?
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []

    // Gesture state, touched only from the framework's callback thread.
    private var gestureStart: Double?
    private var peak = 0
    private var moved = false
    private var misaligned = false
    private var tooLong = false
    private var startPositions: [Int32: MTPoint] = [:]
    private var lastFire: Double = 0
    private var debugFrames = 0

    private init() {}

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        if devices.isEmpty, !load() { return false }
        for device in devices { _ = startFn?(device, 0) }
        isRunning = true
        Settings.log("tap gesture: started on \(devices.count) device(s), fingers=\(fingers) tolerance=\(alignTolerance)")
        return true
    }

    func stop() {
        guard isRunning else { return }
        for device in devices { _ = stopFn?(device) }
        isRunning = false
        reset()
        Settings.log("tap gesture: stopped")
    }

    private func load() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            return fail("MultitouchSupport framework not found")
        }
        guard let createSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else {
            return fail("MultitouchSupport symbols changed in this macOS")
        }
        let createList = unsafeBitCast(createSym, to: CreateListFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        startFn = unsafeBitCast(startSym, to: StartFn.self)
        stopFn = unsafeBitCast(stopSym, to: StopFn.self)

        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
            return fail("no trackpad found")
        }
        deviceList = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, frameCallback)
            devices.append(device)
        }
        unavailableReason = nil
        return true
    }

    private func fail(_ reason: String) -> Bool {
        unavailableReason = reason
        Settings.log("tap gesture unavailable: \(reason)")
        return false
    }

    private func reset() {
        gestureStart = nil
        peak = 0
        moved = false
        misaligned = false
        tooLong = false
        startPositions.removeAll()
    }

    fileprivate func process(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        var down: [(id: Int32, pos: MTPoint)] = []
        if let touches {
            for i in 0..<count {
                let t = touches[i]
                if t.state == 3 || t.state == 4 { down.append((t.identifier, t.normalized.position)) }
            }
            if Settings.shared.debug, count > 0, debugFrames < 40 {
                debugFrames += 1
                let states = (0..<count).map { String(touches[$0].state) }.joined(separator: ",")
                Settings.log("tap gesture frame: contacts=\(count) states=[\(states)] down=\(down.count)")
            }
        }

        if down.isEmpty {
            if let start = gestureStart {
                let duration = timestamp - start
                let fire = peak == fingers && !moved && !misaligned && !tooLong && duration <= maxDuration
                    && timestamp - lastFire > debounce
                Settings.log("tap gesture end: peak=\(peak) moved=\(moved) misaligned=\(misaligned) tooLong=\(tooLong) duration=\(String(format: "%.2f", duration)) fire=\(fire)")
                if fire {
                    lastFire = timestamp
                    DispatchQueue.main.async { [onTap] in onTap?() }
                }
            }
            reset()
            return
        }

        if gestureStart == nil { gestureStart = timestamp }
        peak = max(peak, down.count)
        for finger in down {
            if let start = startPositions[finger.id] {
                if abs(finger.pos.x - start.x) > maxMovement || abs(finger.pos.y - start.y) > maxMovement { moved = true }
            } else {
                startPositions[finger.id] = finger.pos
            }
        }
        if down.count == fingers {
            let ys = down.map { $0.pos.y }
            if (ys.max() ?? 0) - (ys.min() ?? 0) > alignTolerance { misaligned = true }
            let xs = down.map { $0.pos.x }.sorted()
            for i in 1..<xs.count where xs[i] - xs[i - 1] < minFingerGap { misaligned = true }
        }
        if let start = gestureStart, timestamp - start > maxDuration { tooLong = true }
    }
}

private let frameCallback: MTContactCallbackFunction = { _, touches, count, timestamp, _ in
    TrackpadTapDetector.shared.process(touches: touches, count: Int(count), timestamp: timestamp)
    return 0
}
