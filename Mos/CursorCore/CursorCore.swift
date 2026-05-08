//
//  CursorCore.swift
//  Mos
//  指针 (光标) 速度调节模块. 与 ScrollCore 平行, 不修改其行为.
//
//  L1 路径 (本文件): 通过 CGEventTap 截取 mouseMoved/dragged 事件, 按设备分类
//  施加 mouseSpeed / trackpadSpeed 速度倍率. 保留系统加速曲线.
//
//  L2 路径 (LinearPointerSynthesizer): 当 disableMouseAcceleration 启用时,
//  鼠标设备由 IOHIDManager 取原始 HID delta 自行合成 mouseMoved 事件,
//  此时 L1 在该 tap 中识别原始物理事件并丢弃, 避免重复.
//

import Cocoa

class CursorCore {

    static let shared = CursorCore()
    init() { NSLog("Module initialized: CursorCore") }

    var isActive = false

    private var cursorEventInterceptor: Interceptor?

    /// 亚像素累加器, 鼠标和触控板分开维护, 防止小数 delta 截断后丢失移动量.
    private var mouseAcc = (x: 0.0, y: 0.0)
    private var trackpadAcc = (x: 0.0, y: 0.0)

    private let cursorEventMask: CGEventMask = (
        CGEventMask(1 << CGEventType.mouseMoved.rawValue) |
        CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
        CGEventMask(1 << CGEventType.rightMouseDragged.rawValue) |
        CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
    )

    // MARK: - 事件回调

    let cursorEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        _ = (proxy, refcon)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 由 Interceptor 的 keeper / restart 机制兜底
            return Unmanaged.passUnretained(event)
        }

        // 跳过 LinearPointerSynthesizer 自己合成的事件, 避免再次缩放/丢弃
        if event.getIntegerValueField(.eventSourceUserData) == MosEventMarker.syntheticCursor {
            return Unmanaged.passUnretained(event)
        }

        let cursor = Options.shared.cursor
        let deviceClass = PointingDeviceRegistry.shared.classify(forEvent: event)

        // L2 接管: 该设备走线性管线, 物理事件直接丢弃
        if deviceClass == .mouse, cursor.disableMouseAcceleration {
            return nil
        }
        if deviceClass == .trackpad, cursor.affectTrackpadAcceleration {
            return nil
        }

        // 选取速度倍率
        let speed: Double
        switch deviceClass {
        case .trackpad: speed = cursor.trackpadSpeed
        case .mouse, .unknown: speed = cursor.mouseSpeed
        }

        // 倍率 = 1.0 时不做任何修改, 保持系统行为完全一致
        if speed == 1.0 {
            return Unmanaged.passUnretained(event)
        }

        let rawDx = event.getIntegerValueField(.mouseEventDeltaX)
        let rawDy = event.getIntegerValueField(.mouseEventDeltaY)

        // 死区: 单次原始 delta ≤ 1 像素时直接放行, 不做缩放也不改 location.
        // 原因: 慢速精确移动时, 缩放会让 intDx/rawDx 出现 1px 不一致, 而我们
        // 又必须改 event.location 来配平, 这会和 WindowServer 已渲染的光标位置
        // 之间产生 1px 抖动. 在窗口 resize 边缘等敏感区域表现为光标形状闪烁,
        // 在按下鼠标时表现为容易被识别成拖拽. 跳过小位移让慢速移动走系统原生
        // 路径, 高速移动仍然按 speed 倍率缩放, 整体对手感影响最小.
        if abs(rawDx) <= 1 && abs(rawDy) <= 1 {
            // 顺手清掉累加器: 小位移意味着 "连续快速移动" 的假设被打断了,
            // 之前积累的亚像素余量再用反而会引入小误差.
            if deviceClass == .trackpad {
                CursorCore.shared.trackpadAcc = (0, 0)
            } else {
                CursorCore.shared.mouseAcc = (0, 0)
            }
            return Unmanaged.passUnretained(event)
        }

        // 选累加器
        var acc = (deviceClass == .trackpad)
            ? CursorCore.shared.trackpadAcc
            : CursorCore.shared.mouseAcc

        let scaledX = Double(rawDx) * speed + acc.x
        let scaledY = Double(rawDy) * speed + acc.y
        let intDx = Int64(scaledX.rounded(.towardZero))
        let intDy = Int64(scaledY.rounded(.towardZero))
        acc.x = scaledX - Double(intDx)
        acc.y = scaledY - Double(intDy)

        if deviceClass == .trackpad {
            CursorCore.shared.trackpadAcc = acc
        } else {
            CursorCore.shared.mouseAcc = acc
        }

        // 改写 delta + 同步事件 location, 否则 WindowServer 用原始 location
        // 跟踪光标会与系统位置脱节
        event.setIntegerValueField(.mouseEventDeltaX, value: intDx)
        event.setIntegerValueField(.mouseEventDeltaY, value: intDy)
        let oldLoc = event.location
        let newLoc = CGPoint(
            x: oldLoc.x + CGFloat(intDx - rawDx),
            y: oldLoc.y + CGFloat(intDy - rawDy)
        )
        event.location = newLoc
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 生命周期

    func enable() {
        if isActive { return }
        // 总开关关闭时, enable() 是 no-op. 不拦截任何事件, 系统/Logi 等原生
        // 设置完全生效, 等同于"MyMos 没装这部分功能"的状态.
        if !Options.shared.cursor.enabled { return }
        isActive = true

        // 先启动设备登记 (L2 也依赖它, 必须先有)
        PointingDeviceRegistry.shared.start()

        do {
            cursorEventInterceptor = try Interceptor(
                event: cursorEventMask,
                handleBy: cursorEventCallBack,
                listenOn: .cgAnnotatedSessionEventTap,
                placeAt: .headInsertEventTap,
                for: .defaultTap
            )
            cursorEventInterceptor?.onRestart = { [weak self] in
                // 重启 tap 时清空累加器, 防止旧的余量错位
                self?.mouseAcc = (0, 0)
                self?.trackpadAcc = (0, 0)
            }
        } catch {
            NSLog("[CursorCore] Create Interceptor failure: \(error)")
        }

        // 根据当前设置决定是否启动 L2
        refreshAccelerationOverride()
    }

    func disable() {
        if !isActive { return }
        isActive = false
        LinearPointerSynthesizer.shared.stop()
        PointingDeviceRegistry.shared.stop()
        cursorEventInterceptor?.stop()
        cursorEventInterceptor = nil
        mouseAcc = (0, 0)
        trackpadAcc = (0, 0)
    }

    /// Options.cursor 中加速相关的开关变化时调用, 在 L2 与系统默认管线之间切换.
    func refreshAccelerationOverride() {
        let cursor = Options.shared.cursor
        let needL2 = cursor.disableMouseAcceleration || cursor.affectTrackpadAcceleration
        if needL2 {
            LinearPointerSynthesizer.shared.start()
        } else {
            LinearPointerSynthesizer.shared.stop()
        }
    }

    /// Options.cursor.enabled 切换时调用. 关 → 立刻停 (释放 tap, 让原生设置接管),
    /// 开 → 启动 (但只在系统已经启动且有辅助权限时, 走和 AppDelegate 同样的入口).
    func refreshEnabled() {
        let enabled = Options.shared.cursor.enabled
        if enabled {
            // 之前 disable 过, 现在重新启用. enable() 内部已检查权限/状态.
            if !isActive {
                enable()
            }
        } else {
            if isActive {
                disable()
            }
        }
    }
}
