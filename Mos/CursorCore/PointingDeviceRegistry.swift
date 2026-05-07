//
//  PointingDeviceRegistry.swift
//  Mos
//  追踪所有 HID 指针设备并将其分类为 鼠标 / 触控板, 用于按设备来源
//  路由 CursorCore (L1) 的速度缩放与 LinearPointerSynthesizer (L2) 的线性合成.
//

import Cocoa
import IOKit.hid

enum PointingDeviceClass {
    case mouse
    case trackpad
    case unknown
}

/// 设备入站回调签名: (deviceID, deviceClass, rawDx, rawDy)
/// 当 LinearPointerSynthesizer 注册了这个 hook 时, 每次 HID input 都会先回调它.
typealias PointingDeviceInputHook = (UInt64, PointingDeviceClass, Int, Int) -> Void

class PointingDeviceRegistry {

    static let shared = PointingDeviceRegistry()
    init() { NSLog("Module initialized: PointingDeviceRegistry") }

    private var hidManager: IOHIDManager?
    private var hidThread: Thread?
    private var hidRunLoop: CFRunLoop?
    private var deviceMap: [UInt64: PointingDeviceClass] = [:]
    private let mapLock = NSLock()

    /// 由 LinearPointerSynthesizer 注入: 当物理设备产生 HID input 时被调用.
    /// 不持有 self, 由调用方在 stop 时清空.
    var inputHook: PointingDeviceInputHook?

    func start() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // 匹配指针类设备 (鼠标 + 触控板)
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey:    kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey:    kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let me = Unmanaged<PointingDeviceRegistry>.fromOpaque(ctx).takeUnretainedValue()
            me.handleDeviceAdded(device)
        }, opaque)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let me = Unmanaged<PointingDeviceRegistry>.fromOpaque(ctx).takeUnretainedValue()
            me.handleDeviceRemoved(device)
        }, opaque)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            let me = Unmanaged<PointingDeviceRegistry>.fromOpaque(ctx).takeUnretainedValue()
            me.handleInputValue(value)
        }, opaque)
        // IOHID 跑在独立后台线程上, 而不是主 RunLoop. 原因:
        // 1. 鼠标手放上去就会持续微抖, HID 事件 100-1000Hz, 在主线程跑会和
        //    AppKit / 中文 IME / 渲染竞争, 导致打字卡顿.
        // 2. 之前用 main+commonModes 是为了修拖拽时光标跳, 但代价是主线程繁忙.
        //    搬到后台线程后, RunLoop mode 切换的问题彻底不存在 (后台线程的 RunLoop
        //    永远在 defaultMode 上跑).
        // CGEvent.post 是线程安全的, 所以从后台线程合成事件没问题.
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self = self else { semaphore.signal(); return }
            guard let runLoop = CFRunLoopGetCurrent() else { semaphore.signal(); return }
            self.hidRunLoop = runLoop
            IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if openResult != kIOReturnSuccess {
                NSLog("[PointingDeviceRegistry] IOHIDManagerOpen failed: 0x\(String(openResult, radix: 16))")
            }
            semaphore.signal()
            // 保持 RunLoop 一直跑, 每秒检查一次是否被 cancel
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        thread.qualityOfService = .userInteractive
        thread.name = "MyMos.HIDInput"
        thread.start()
        semaphore.wait()  // 等线程启动并完成 schedule + open

        hidManager = manager
        hidThread = thread
    }

    func stop() {
        guard hidManager != nil else { return }
        hidThread?.cancel()  // 后台线程会在下一个 1s tick 内退出并清理 manager
        hidThread = nil
        hidRunLoop = nil
        hidManager = nil
        mapLock.lock(); deviceMap.removeAll(); mapLock.unlock()
        inputHook = nil
    }

    /// 根据 CGEvent 的 kCGMouseEventInstanceUserData 字段找到来源设备的分类.
    /// 找不到时回退为 .mouse — 这是更安全的默认 (用户通常用鼠标, 误将触控板归为
    /// 鼠标只会让其按 mouseSpeed 缩放, 而不会进入 L2 强制线性化路径).
    func classify(forEvent event: CGEvent) -> PointingDeviceClass {
        let id = UInt64(bitPattern: Int64(event.getIntegerValueField(CGEventField(rawValue: 164)!)))
        mapLock.lock(); defer { mapLock.unlock() }
        return deviceMap[id] ?? .mouse
    }

    // MARK: - 内部回调

    private func handleDeviceAdded(_ device: IOHIDDevice) {
        let id = senderID(for: device)
        let cls = Self.classify(device)
        mapLock.lock(); deviceMap[id] = cls; mapLock.unlock()
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "<unknown>"
        NSLog("[PointingDeviceRegistry] device added id=\(id) class=\(cls) name=\(name)")
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let id = senderID(for: device)
        mapLock.lock(); deviceMap.removeValue(forKey: id); mapLock.unlock()
    }

    private func handleInputValue(_ value: IOHIDValue) {
        guard inputHook != nil else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard usagePage == kHIDPage_GenericDesktop,
              (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y) else { return }
        let intVal = IOHIDValueGetIntegerValue(value)
        guard intVal != 0 else { return }
        let device = IOHIDElementGetDevice(element)
        let id = senderID(for: device)
        mapLock.lock(); let cls = deviceMap[id] ?? .unknown; mapLock.unlock()
        if usage == kHIDUsage_GD_X {
            inputHook?(id, cls, intVal, 0)
        } else {
            inputHook?(id, cls, 0, intVal)
        }
    }

    /// 通过 IOService registry entry ID 获取一个会话内稳定的设备 ID.
    /// 这个值和 CGEvent 上的 kCGMouseEventInstanceUserData 一致, 用于跨 HIDManager
    /// 与 CGEventTap 两条路径匹配同一台设备.
    private func senderID(for device: IOHIDDevice) -> UInt64 {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else {
            return UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque().hashValue))
        }
        var entryID: UInt64 = 0
        let kr = IORegistryEntryGetRegistryEntryID(service, &entryID)
        if kr == KERN_SUCCESS {
            return entryID
        }
        return UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque().hashValue))
    }

    // MARK: - 设备分类

    /// 判断 IOHIDDevice 是鼠标还是触控板.
    /// CGEvent 的 subtype 字段在现代 macOS 上无法可靠区分两者, 必须借助 HID 属性.
    static func classify(_ device: IOHIDDevice) -> PointingDeviceClass {
        // 1. 优先 usage page/usage
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePageKey as CFString) as? Int) ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsageKey as CFString) as? Int) ?? 0

        // 2. 名称 / vendor 辅助识别
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let lname = name.lowercased()
        if lname.contains("trackpad") || lname.contains("magic trackpad") {
            return .trackpad
        }

        // Apple 触控板 vendor=0x05AC. 内置触控板多以 "Apple Internal Keyboard / Trackpad" 注册,
        // 已被名字匹配命中. Magic Trackpad 命中名字, 不需要按 PID 拆.
        // 显式 Mouse usage 的设备直接判鼠标
        if usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Mouse {
            return .mouse
        }
        if usagePage == kHIDPage_Digitizer {
            return .trackpad
        }
        // 默认按鼠标处理 (保守: 只缩放速度, 不进入 L2 线性管线)
        return .mouse
    }
}
