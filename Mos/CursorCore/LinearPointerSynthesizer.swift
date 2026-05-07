//
//  LinearPointerSynthesizer.swift
//  Mos
//  CursorCore L2: 当用户启用 "禁用鼠标加速" 时, 通过 IOHIDManager 监听
//  目标设备的原始 HID delta, 跳过系统加速曲线, 自行合成 mouseMoved 事件.
//
//  设计要点:
//  1. 依赖 PointingDeviceRegistry 提供的 inputHook 接收 (deviceID, class, dx, dy).
//  2. 维护一个 virtualLocation 累加器, 初值取自 NSEvent.mouseLocation.
//  3. 合成的 CGEvent 通过 eventSourceUserData = MosEventMarker.syntheticCursor
//     标记, 供 L1 (CursorCore) 跳过.
//  4. 物理事件由 CursorCore 在 L1 tap 中按 disableMouseAcceleration /
//     affectTrackpadAcceleration 决定是否丢弃.
//

import Cocoa
import IOKit.hid

class LinearPointerSynthesizer {

    static let shared = LinearPointerSynthesizer()
    init() { NSLog("Module initialized: LinearPointerSynthesizer") }

    private var isRunning = false
    /// 虚拟光标位置, 在 start() 时从系统当前光标同步, 之后由 raw HID delta 增量驱动.
    private var virtualLocation: CGPoint = .zero
    private let lock = NSLock()

    /// 把 HID 原始 count 转换到 "屏幕逻辑像素" 的基线缩放. macOS 默认加速曲线在
    /// 低速段会压缩 delta, 因此 raw HID 大约是 "系统中速档" 的 2 倍左右. 取 0.5
    /// 让 1.0× 速度大致接近系统默认速度感受. 用户可再用 slider 微调.
    private let linearBaseScale: Double = 0.5

    /// PointingDeviceRegistry 现在把回调发到后台线程, 所以 inputHook 闭包以及 handleRawHID
    /// 都跑在后台线程. NSEvent / NSScreen 在后台线程不安全, 所以本类内部一律改用线程安全的
    /// CG / CoreGraphics API. 唯一仍可能在主线程跑的是 start(), 在那里完成初始 cursor 同步,
    /// 让回调线程不必再读 NSEvent.mouseLocation.
    func start() {
        lock.lock(); defer { lock.unlock() }
        if isRunning { return }
        isRunning = true

        // 在调用方 (主线程) 上同步一次系统光标位置. 之后所有回调都在后台线程,
        // virtualLocation 由 raw HID delta 增量驱动, 不再访问 NSEvent / NSScreen.
        if let event = CGEvent(source: nil) {
            virtualLocation = event.location
        }

        PointingDeviceRegistry.shared.inputHook = { [weak self] deviceID, cls, rawDx, rawDy in
            self?.handleRawHID(deviceID: deviceID, deviceClass: cls, rawDx: rawDx, rawDy: rawDy)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !isRunning { return }
        isRunning = false
        PointingDeviceRegistry.shared.inputHook = nil
    }

    // MARK: - HID 输入处理

    private func handleRawHID(deviceID: UInt64, deviceClass: PointingDeviceClass, rawDx: Int, rawDy: Int) {
        let cursor = Options.shared.cursor
        // 是否对该设备启用 L2 线性管线
        let active: Bool
        switch deviceClass {
        case .mouse, .unknown: active = cursor.disableMouseAcceleration
        case .trackpad:        active = cursor.affectTrackpadAcceleration
        }
        if !active { return }

        // 速度倍率
        let speed: Double
        switch deviceClass {
        case .trackpad: speed = cursor.trackpadSpeed
        case .mouse, .unknown: speed = cursor.mouseSpeed
        }

        lock.lock()
        // 应用线性映射 (含 baseScale 校准, 让 1.0× 接近系统默认速度)
        let factor = speed * linearBaseScale
        var newX = virtualLocation.x + CGFloat(Double(rawDx) * factor)
        var newY = virtualLocation.y + CGFloat(Double(rawDy) * factor)
        // 屏幕边界 clip (取所有屏幕的并集)
        let bounds = LinearPointerSynthesizer.unifiedScreenBounds()
        if !bounds.isEmpty {
            newX = max(bounds.minX, min(bounds.maxX - 1, newX))
            newY = max(bounds.minY, min(bounds.maxY - 1, newY))
        }
        virtualLocation = CGPoint(x: newX, y: newY)
        let postLoc = virtualLocation
        lock.unlock()

        postSynthesizedMove(at: postLoc)
    }

    private func postSynthesizedMove(at point: CGPoint) {
        // 根据当前按下的鼠标按键, 合成对应的事件类型. 否则在按住按键拖动时,
        // 系统不会收到 "拖拽中" 信号, 导致拖动无效或高延迟.
        // CGEventSource.buttonState 线程安全, 可在 HID 后台线程调用;
        // 而 NSEvent.pressedMouseButtons 不保证后台线程安全.
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            mouseType = .leftMouseDragged
            mouseButton = .left
        } else if CGEventSource.buttonState(.combinedSessionState, button: .right) {
            mouseType = .rightMouseDragged
            mouseButton = .right
        } else if CGEventSource.buttonState(.combinedSessionState, button: .center) {
            mouseType = .otherMouseDragged
            mouseButton = .center
        } else {
            mouseType = .mouseMoved
            mouseButton = .left
        }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCursor)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - 工具

    /// 全部屏幕的 union, 已在 CG 坐标系 (左上原点).
    /// 用 CGGetActiveDisplayList + CGDisplayBounds 是为了线程安全 — 这两个 API 可在
    /// 任意线程调用, 而 NSScreen 不保证后台线程安全.
    private static func unifiedScreenBounds() -> CGRect {
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let err = CGGetActiveDisplayList(maxDisplays, &displays, &count)
        guard err == .success, count > 0 else { return .zero }
        var union = CGRect.null
        for i in 0..<Int(count) {
            let bounds = CGDisplayBounds(displays[i])  // 已是 CG 坐标
            union = union.isNull ? bounds : union.union(bounds)
        }
        return union
    }
}
