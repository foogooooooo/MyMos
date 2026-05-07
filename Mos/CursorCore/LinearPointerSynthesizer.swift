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
    /// 虚拟光标位置, 与系统光标位置同步. 第一次合成前会被 syncFromSystem 重置.
    private var virtualLocation: CGPoint = .zero
    private var hasSynced = false
    private let lock = NSLock()

    /// 把 HID 原始 count 转换到 "屏幕逻辑像素" 的基线缩放. macOS 默认加速曲线在
    /// 低速段会压缩 delta, 因此 raw HID 大约是 "系统中速档" 的 2 倍左右. 取 0.5
    /// 让 1.0× 速度大致接近系统默认速度感受. 用户可再用 slider 微调.
    private let linearBaseScale: Double = 0.5

    /// 由 PointingDeviceRegistry 在主 RunLoop 上调用. 此处全部在主线程, 不需额外加锁,
    /// 但 isRunning / virtualLocation 仍用 lock 保护以防外部 stop() 与回调竞争.
    func start() {
        lock.lock(); defer { lock.unlock() }
        if isRunning { return }
        isRunning = true
        hasSynced = false
        // 注入 hook
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
        if !hasSynced {
            virtualLocation = NSEvent.mouseLocation
            // NSEvent.mouseLocation 是以左下角为原点, 而 CGEvent 用左上角为原点,
            // 在合成 CGEvent 时统一用 CG 坐标系. 这里转换一次.
            virtualLocation = LinearPointerSynthesizer.flipToCGCoords(virtualLocation)
            hasSynced = true
        }
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
        let pressed = NSEvent.pressedMouseButtons
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        if (pressed & (1 << 0)) != 0 {
            mouseType = .leftMouseDragged
            mouseButton = .left
        } else if (pressed & (1 << 1)) != 0 {
            mouseType = .rightMouseDragged
            mouseButton = .right
        } else if pressed != 0 {
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

    /// 把 NS 坐标 (左下原点) 转为 CG 坐标 (左上原点).
    private static func flipToCGCoords(_ p: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return p }
        return CGPoint(x: p.x, y: primary.frame.height - p.y)
    }

    /// 全部屏幕的 union, 用 CG 坐标系 (左上原点).
    private static func unifiedScreenBounds() -> CGRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return .zero }
        let primaryHeight = primary.frame.height
        var union = CGRect.null
        for s in screens {
            let f = s.frame
            // f 是 NS 坐标. 转为 CG 坐标: y_cg = primaryH - (y_ns + h)
            let cg = CGRect(
                x: f.origin.x,
                y: primaryHeight - (f.origin.y + f.height),
                width: f.width,
                height: f.height
            )
            union = union.isNull ? cg : union.union(cg)
        }
        return union
    }
}
