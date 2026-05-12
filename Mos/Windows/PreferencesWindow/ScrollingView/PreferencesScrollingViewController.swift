//
//  PreferencesScrollingViewController.swift
//  Mos
//  滚动选项界面
//  Created by Caldis on 2017/1/26.
//  Copyright © 2017年 Caldis. All rights reserved.
//

import Cocoa

class PreferencesScrollingViewController: NSViewController, ScrollOptionsContextProviding {

    // Target application
    // - Using when the VC is inside the Application Setting Popup
    var currentTargetApplication: Application?
    // UI Elements
    @IBOutlet weak var scrollSmoothCheckBox: NSButton!
    @IBOutlet weak var scrollReverseCheckBox: NSButton!
    @IBOutlet weak var dashKeyBindButton: NSButton!
    @IBOutlet weak var dashKeyDelButton: NSButton!
    @IBOutlet weak var toggleKeyBindButton: NSButton!
    @IBOutlet weak var toggleKeyDelButton: NSButton!
    @IBOutlet weak var disableKeyBindButton: NSButton!
    @IBOutlet weak var disableKeyDelButton: NSButton!
    @IBOutlet weak var scrollStepSlider: NSSlider!
    @IBOutlet weak var scrollStepInput: NSTextField!
    @IBOutlet weak var scrollStepStepper: NSStepper!
    @IBOutlet weak var scrollSpeedSlider: NSSlider!
    @IBOutlet weak var scrollSpeedInput: NSTextField!
    @IBOutlet weak var scrollSpeedStepper: NSStepper!
    @IBOutlet weak var scrollDurationSlider: NSSlider!
    @IBOutlet weak var scrollDurationInput: NSTextField!
    @IBOutlet weak var scrollDurationStepper: NSStepper!
    @IBOutlet weak var scrollDurationDescriptionLabel: NSTextField?
    @IBOutlet weak var resetToDefaultsButton: NSButton!
    @IBOutlet weak var manageHoldScrollButton: NSButton?
    @IBOutlet weak var invertBlockKeyCheckbox: NSButton?
    @IBOutlet weak var modifierLongPressCheckbox: NSButton?
    var resetButtonHeightConstraint: NSLayoutConstraint?
    private var helpPopover: NSPopover?
    // Constants
    let DefaultConfigForCompare = OPTIONS_SCROLL_DEFAULT()
    private var scrollDurationDescriptionDefaultText: String?
    private let scrollDurationLockedDescription = NSLocalizedString(
        "scrollDurationLockedMessage",
        comment: "Message shown when simulate trackpad locks the duration setting"
    )
    // KeyRecorder for custom hotkey recording
    private let keyRecorder = KeyRecorder()
    private weak var currentRecordingPopup: NSButton?
    // 自定义 hold-scroll 绑定 sheet (持有引用避免 sheet 关闭后被释放)
    private var holdScrollWindowController: HoldScrollBindingsWindowController?

    override func viewDidLoad() {
        // 禁止自动 Focus
        scrollStepInput.refusesFirstResponder = true
        scrollSpeedInput.refusesFirstResponder = true
        scrollDurationInput.refusesFirstResponder = true
        // 创建高度约束
        resetButtonHeightConstraint = resetToDefaultsButton.heightAnchor.constraint(equalToConstant: 24)
        resetButtonHeightConstraint?.isActive = true
        scrollDurationDescriptionDefaultText = scrollDurationDescriptionLabel?.stringValue
        // 设置 KeyRecorder 代理
        keyRecorder.delegate = self
        // storyboard 里这几个新控件的标题是英文源, runtime 用 NSLocalizedString 覆盖.
        // (避免和 Localizable.xcstrings 现有 key 产生 Swift 符号冲突)
        invertBlockKeyCheckbox?.title = NSLocalizedString(
            "Make precise scrolling the default — hold the Disable Smoothing key to temporarily enable smooth scrolling",
            comment: "Invert block key checkbox label"
        )
        modifierLongPressCheckbox?.title = NSLocalizedString(
            "Modifier keys must be long-pressed to trigger (avoids accidental firing on Cmd+C etc.)",
            comment: "Modifier long-press checkbox label"
        )
        manageHoldScrollButton?.title = NSLocalizedString(
            "Manage Hold-Scroll Shortcuts",
            comment: "Hold-scroll bindings sheet title"
        ) + "…"
        // 读取设置
        syncViewWithOptions()
    }

    // MARK: - Help popovers for the three sliders / precision-first checkbox

    @IBAction func stepHelpClicked(_ sender: NSButton) {
        sender.helpTitle = NSLocalizedString("Min Step (Per Notch)", comment: "Help title: step")
        sender.helpBody = NSLocalizedString(
            "How far the page moves on a single wheel notch — the minimum scroll distance per click.\n\nLarger values: each click of the wheel moves the page more (snappier, jumpier).\nSmaller values: each click moves less (finer, slower).\n\nThink of it as the floor amount for one wheel tick before any smoothing easing kicks in.",
            comment: "Help body: step"
        )
        helpPopover = ScrollHelp.showOrTogglePopover(from: sender, current: helpPopover)
    }

    @IBAction func speedHelpClicked(_ sender: NSButton) {
        sender.helpTitle = NSLocalizedString("Speed Gain", comment: "Help title: speed")
        sender.helpBody = NSLocalizedString(
            "How much momentum the scroll picks up when you keep scrolling.\n\nLarger values: continuous scrolling accelerates faster — flicking the wheel sends the page further.\nSmaller values: each notch contributes the same amount; no acceleration.\n\nUse it to dial in how quickly long pages fly past when you spin the wheel.",
            comment: "Help body: speed"
        )
        helpPopover = ScrollHelp.showOrTogglePopover(from: sender, current: helpPopover)
    }

    @IBAction func durationHelpClicked(_ sender: NSButton) {
        sender.helpTitle = NSLocalizedString("Duration", comment: "Help title: duration")
        sender.helpBody = NSLocalizedString(
            "How long the smooth-scroll easing animation lasts after each notch.\n\nLarger values: the page glides on after you stop (longer trailing motion, more trackpad-feel).\nSmaller values: motion stops quickly when you stop scrolling (snappier).\n\nThis only applies when Smooth Scrolling is enabled.",
            comment: "Help body: duration"
        )
        helpPopover = ScrollHelp.showOrTogglePopover(from: sender, current: helpPopover)
    }

    // MARK: - Precision-first mode

    @IBAction func invertBlockKeyChanged(_ sender: NSButton) {
        getTargetApplicationScrollOptions().invertBlockKey = sender.state == .on
    }

    @IBAction func modifierLongPressChanged(_ sender: NSButton) {
        getTargetApplicationScrollOptions().modifierHotkeyLongPress = sender.state == .on
    }

    @IBAction func manageHoldScrollClicked(_ sender: NSButton) {
        let controller: HoldScrollBindingsWindowController
        if let app = currentTargetApplication {
            controller = HoldScrollBindingsWindowController(application: app)
        } else {
            controller = HoldScrollBindingsWindowController()
        }
        holdScrollWindowController = controller
        guard let parentWindow = view.window, let sheetWindow = controller.window else { return }
        parentWindow.beginSheet(sheetWindow) { [weak self] _ in
            self?.holdScrollWindowController = nil
        }
    }

    override func prepare(for segue: NSStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)
        if let smoothPopover = segue.destinationController as? ScrollSmoothDetailSettingsPopoverViewController {
            smoothPopover.currentTargetApplication = currentTargetApplication
            smoothPopover.onOptionsChanged = { [weak self] in
                self?.syncViewWithOptions()
            }
        } else if let reversePopover = segue.destinationController as? ScrollReverseDetailSettingsPopoverViewController {
            reversePopover.currentTargetApplication = currentTargetApplication
            reversePopover.onOptionsChanged = { [weak self] in
                self?.syncViewWithOptions()
            }
        }
    }
    
    // 平滑
    @IBAction func scrollSmoothClick(_ sender: NSButton) {
        getTargetApplicationScrollOptions().smooth = sender.state.rawValue != 0
        syncViewWithOptions()
    }

    // 翻转
    @IBAction func scrollReverseClick(_ sender: NSButton) {
        getTargetApplicationScrollOptions().reverse = sender.state.rawValue != 0
        syncViewWithOptions()
    }
    
    // 加速键 - 点击触发录制
    @IBAction func dashKeyButtonClick(_ sender: NSButton) {
        currentRecordingPopup = sender
        keyRecorder.startRecording(from: sender, mode: .singleKey)
    }
    // 加速键 - 清除绑定
    @IBAction func dashKeyDelButtonClick(_ sender: NSButton) {
        getTargetApplicationScrollOptions().dash = nil
        syncViewWithOptions()
        pushCurrentScopeUsage(roles: [.dash])
    }
    // 转换键 - 点击触发录制
    @IBAction func toggleKeyButtonClick(_ sender: NSButton) {
        currentRecordingPopup = sender
        keyRecorder.startRecording(from: sender, mode: .singleKey)
    }
    // 转换键 - 清除绑定
    @IBAction func toggleKeyDelButtonClick(_ sender: NSButton) {
        getTargetApplicationScrollOptions().toggle = nil
        syncViewWithOptions()
        pushCurrentScopeUsage(roles: [.toggle])
    }
    // 禁用键 - 点击触发录制
    @IBAction func disableKeyButtonClick(_ sender: NSButton) {
        currentRecordingPopup = sender
        keyRecorder.startRecording(from: sender, mode: .singleKey)
    }
    // 禁用键 - 清除绑定
    @IBAction func disableKeyDelButtonClick(_ sender: NSButton) {
        getTargetApplicationScrollOptions().block = nil
        syncViewWithOptions()
        pushCurrentScopeUsage(roles: [.block])
    }
    
    // 步长
    @IBAction func scrollStepSliderChange(_ sender: NSSlider) {
        setScrollStep(value: sender.doubleValue)
    }
    @IBAction func scrollStepInputChange(_ sender: NSTextField) {
        setScrollStep(value: sender.doubleValue)
    }
    @IBAction func scrollStepStepperChange(_ sender: NSStepper) {
        setScrollStep(value: sender.doubleValue)
    }
    func setScrollStep(value: Double) {
        getTargetApplicationScrollOptions().step = value
        syncViewWithOptions()
    }
    
    // 速度
    @IBAction func scrollSpeedSliderChange(_ sender: NSSlider) {
        setScrollSpeed(value: sender.doubleValue)
    }
    @IBAction func scrollSpeedInputChange(_ sender: NSTextField) {
        setScrollSpeed(value: sender.doubleValue)
    }
    @IBAction func scrollSpeedStepperChange(_ sender: NSStepper) {
        setScrollSpeed(value: sender.doubleValue)
    }
    func setScrollSpeed(value: Double) {
        getTargetApplicationScrollOptions().speed = value
        syncViewWithOptions()
    }
    
    // 过渡
    @IBAction func scrollDurationSliderChange(_ sender: NSSlider) {
        setScrollDuration(value: sender.doubleValue)
    }
    @IBAction func scrollDurationInputChange(_ sender: NSTextField) {
        setScrollDuration(value: sender.doubleValue)
    }
    @IBAction func scrollDurationStepperChange(_ sender: NSStepper) {
        setScrollDuration(value: sender.doubleValue)
    }
    func setScrollDuration(value: Double) {
        let scrollOptions = getTargetApplicationScrollOptions()
        if scrollOptions.smoothSimTrackpad {
            scrollOptions.duration = ScrollDurationLimits.simulateTrackpadDefault
        } else {
            scrollOptions.duration = value
        }
        syncViewWithOptions()
    }
    
    // 重置
    @IBAction func resetToDefaultClick(_ sender: NSButton) {
        if let target = currentTargetApplication {
            target.scroll = OPTIONS_SCROLL_DEFAULT()
        } else {
            Options.shared.scroll = OPTIONS_SCROLL_DEFAULT()
        }
        syncViewWithOptions()
        pushCurrentScopeUsage(roles: [.dash, .toggle, .block])
    }

}

/**
 * 工具函数
 **/
extension PreferencesScrollingViewController {
    // 同步界面与设置
    func syncViewWithOptions() {
        // 是否继承配置
        let isNotInherit = !isTargetApplicationInheritOptions()
        // 滚动配置
        let scroll = getTargetApplicationScrollOptions()
        // 平滑
        scrollSmoothCheckBox.state = NSControl.StateValue(rawValue: scroll.smooth ? 1 : 0)
        scrollSmoothCheckBox.isEnabled = isNotInherit
        // 翻转
        scrollReverseCheckBox.state = NSControl.StateValue(rawValue: scroll.reverse ? 1 : 0)
        scrollReverseCheckBox.isEnabled = isNotInherit
        // 自定义"按住键 + 滚动"入口按钮
        manageHoldScrollButton?.isEnabled = isNotInherit
        // 精确滚动优先 checkbox
        invertBlockKeyCheckbox?.state = scroll.invertBlockKey ? .on : .off
        invertBlockKeyCheckbox?.isEnabled = isNotInherit
        // 修饰键长按生效 checkbox
        modifierLongPressCheckbox?.state = scroll.modifierHotkeyLongPress ? .on : .off
        modifierLongPressCheckbox?.isEnabled = isNotInherit
        // 加速键
        updateHotkeyButton(dashKeyBindButton, delButton: dashKeyDelButton, hotkey: scroll.dash, enabled: isNotInherit)
        // 转换键
        updateHotkeyButton(toggleKeyBindButton, delButton: toggleKeyDelButton, hotkey: scroll.toggle, enabled: isNotInherit)
        // 禁用键
        updateHotkeyButton(disableKeyBindButton, delButton: disableKeyDelButton, hotkey: scroll.block, enabled: isNotInherit)
        // 步长
        let step = scroll.step
        scrollStepSlider.doubleValue = step
        scrollStepSlider.isEnabled = isNotInherit
        scrollStepStepper.doubleValue = step
        scrollStepStepper.isEnabled = isNotInherit
        scrollStepInput.stringValue = String(format: "%.2f", step)
        scrollStepInput.isEnabled = isNotInherit
        // 速度
        let speed = scroll.speed
        scrollSpeedSlider.doubleValue = speed
        scrollSpeedSlider.isEnabled = isNotInherit
        scrollSpeedStepper.doubleValue = speed
        scrollSpeedStepper.isEnabled = isNotInherit
        scrollSpeedInput.stringValue = String(format: "%.2f", speed)
        scrollSpeedInput.isEnabled = isNotInherit
        // 过渡
        let isSimTrackpadEnabled = scroll.smoothSimTrackpad
        let resolvedDuration: Double
        if isSimTrackpadEnabled {
            resolvedDuration = ScrollDurationLimits.simulateTrackpadDefault
            if scroll.duration != resolvedDuration {
                scroll.duration = resolvedDuration
            }
        } else {
            resolvedDuration = scroll.duration
        }
        scrollDurationSlider.doubleValue = resolvedDuration
        scrollDurationSlider.isEnabled = isNotInherit && !isSimTrackpadEnabled
        scrollDurationStepper.doubleValue = resolvedDuration
        scrollDurationStepper.isEnabled = isNotInherit && !isSimTrackpadEnabled
        scrollDurationInput.stringValue = String(format: "%.2f", resolvedDuration)
        scrollDurationInput.isEnabled = isNotInherit && !isSimTrackpadEnabled
        if isSimTrackpadEnabled {
            scrollDurationDescriptionLabel?.stringValue = scrollDurationLockedDescription
        } else if let defaultText = scrollDurationDescriptionDefaultText {
            scrollDurationDescriptionLabel?.stringValue = defaultText
        }
        // 更新重置按钮状态
        updateResetButtonState()
    }
    // 更新重置按钮状态与显示
    func updateResetButtonState() {
        let isNotInherit = !isTargetApplicationInheritOptions()
        let scroll = getTargetApplicationScrollOptions()
        let shouldShowResetButton = isNotInherit && scroll != DefaultConfigForCompare
        // 动画过渡
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ANIMATION.duration
            context.allowsImplicitAnimation = true
            resetToDefaultsButton.animator().isEnabled = shouldShowResetButton
            resetToDefaultsButton.animator().alphaValue = shouldShowResetButton ? 1.0 : 0.0
            resetButtonHeightConstraint?.animator().constant = shouldShowResetButton ? 24 : 0
        }, completionHandler: {
            // 触发父视图窗口尺寸更新
            self.view.needsLayout = true
            self.view.layout()
            (self.parent as? PreferencesTabViewController)?.updateWindowSize()
        })
    }

    // MARK: - Logi Usage Push

    /// 根据当前作用域 (全局 / 指定 App) 推送 ScrollHotkey 绑定到 LogiCenter
    /// - 当 currentTargetApplication == nil 时使用 .globalScroll(role)
    /// - 当 currentTargetApplication != nil 且 !inherit 时使用 .appScroll(key:role:)
    /// - 当 currentTargetApplication != nil 且 inherit 时不推送 (由 Task 3.9 的 clearAppUsage 处理)
    private func pushCurrentScopeUsage(roles: [ScrollRole]) {
        if let app = currentTargetApplication {
            guard !app.inherit else { return }
            for role in roles {
                LogiCenter.shared.setUsage(
                    source: .appScroll(key: app.path, role: role),
                    codes: collectAppScrollCodes(app: app, role: role)
                )
            }
        } else {
            for role in roles {
                LogiCenter.shared.setUsage(
                    source: .globalScroll(role),
                    codes: collectGlobalScrollCodes(role: role)
                )
            }
        }
    }

    /// 提取全局 scroll 配置中指定 role 对应的 Logi 鼠标按键码
    private func collectGlobalScrollCodes(role: ScrollRole) -> Set<UInt16> {
        let hotkey: ScrollHotkey? = {
            switch role {
            case .dash:   return Options.shared.scroll.dash
            case .toggle: return Options.shared.scroll.toggle
            case .block:  return Options.shared.scroll.block
            }
        }()
        guard let h = hotkey, h.type == .mouse, LogiCenter.shared.isLogiCode(h.code) else {
            return []
        }
        return [h.code]
    }

    /// 提取指定 App scroll 配置中 role 对应的 Logi 鼠标按键码
    private func collectAppScrollCodes(app: Application, role: ScrollRole) -> Set<UInt16> {
        let hotkey: ScrollHotkey? = {
            switch role {
            case .dash:   return app.scroll.dash
            case .toggle: return app.scroll.toggle
            case .block:  return app.scroll.block
            }
        }()
        guard let h = hotkey, h.type == .mouse, LogiCenter.shared.isLogiCode(h.code) else {
            return []
        }
        return [h.code]
    }

    /// 键盘按键的完整名称映射 (仅用于 ScrollingView 按钮显示)
    private static let keyFullNames: [UInt16: String] = [
        // 修饰键
        KeyCode.commandL: "⌘ Command",
        KeyCode.commandR: "⌘ Command",
        KeyCode.optionL: "⌥ Option",
        KeyCode.optionR: "⌥ Option",
        KeyCode.shiftL: "⇧ Shift",
        KeyCode.shiftR: "⇧ Shift",
        KeyCode.controlL: "⌃ Control",
        KeyCode.controlR: "⌃ Control",
        KeyCode.fnL: "Fn",
        KeyCode.fnR: "Fn",
        // 特殊键
        49: "⎵ Space",
        51: "⌫ Delete",
        53: "⎋ Escape",
        36: "↩ Return",
        76: "↩ Return",
        48: "↹ Tab",
    ]

    /// 获取 ScrollHotkey 的完整显示名称
    /// 获取按键基础名称 (不含品牌前缀)
    private func getBaseDisplayName(for hotkey: ScrollHotkey) -> String {
        switch hotkey.type {
        case .keyboard:
            if let fullName = PreferencesScrollingViewController.keyFullNames[hotkey.code] {
                return fullName
            }
            return KeyCode.keyMap[hotkey.code] ?? "Key \(hotkey.code)"
        case .mouse:
            if LogiCenter.shared.isLogiCode(hotkey.code) {
                return (LogiCenter.shared.name(forMosCode: hotkey.code) ?? "")
            }
            return KeyCode.mouseMap[hotkey.code] ?? "🖱\(hotkey.code)"
        }
    }

    /// 获取完整显示名称 (含品牌前缀, 用于纯文本场景)
    private func getFullDisplayName(for hotkey: ScrollHotkey) -> String {
        let baseName = getBaseDisplayName(for: hotkey)
        if let brand = BrandTag.brandForCode(hotkey.code) {
            return BrandTag.prefixedName(baseName, brand: brand)
        }
        return baseName
    }

    /// 更新热键按钮的显示文本和删除按钮可见性
    private func updateHotkeyButton(_ button: NSButton?, delButton: NSButton?, hotkey: ScrollHotkey?, enabled: Bool) {
        guard let button = button else { return }

        let hasBound = hotkey != nil

        // 设置按钮标题
        if let hotkey = hotkey {
            let baseName = getBaseDisplayName(for: hotkey)
            if let brand = BrandTag.brandForCode(hotkey.code) {
                // 品牌按键: image=tag, title=名称, 左图右文
                button.image = BrandTag.createTagImage(brand: brand, fontSize: 7, height: 14, padH: 5, marginRight: 4)
                button.imagePosition = .imageLeft
                button.title = baseName
            } else {
                button.image = nil
                button.imagePosition = .noImage
                button.title = getFullDisplayName(for: hotkey)
            }
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = NSLocalizedString("Disabled", comment: "Hotkey disabled state")
        }

        button.isEnabled = enabled

        // 设置删除按钮可见性：仅在有绑定且启用时显示
        delButton?.alphaValue = (hasBound && enabled) ? 1.0 : 0.0
        delButton?.isEnabled = hasBound && enabled
    }
}

// MARK: - KeyRecorderDelegate
extension PreferencesScrollingViewController: KeyRecorderDelegate {
    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: InputEvent, isDuplicate: Bool) {
        guard let popup = currentRecordingPopup else { return }

        let hotkey = ScrollHotkey(from: event)

        if popup === dashKeyBindButton {
            getTargetApplicationScrollOptions().dash = hotkey
        } else if popup === toggleKeyBindButton {
            getTargetApplicationScrollOptions().toggle = hotkey
        } else if popup === disableKeyBindButton {
            getTargetApplicationScrollOptions().block = hotkey
        }

        currentRecordingPopup = nil
        syncViewWithOptions()
        pushCurrentScopeUsage(roles: [.dash, .toggle, .block])
    }
}
