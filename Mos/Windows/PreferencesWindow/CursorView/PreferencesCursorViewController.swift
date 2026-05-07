//
//  PreferencesCursorViewController.swift
//  Mos
//  光标 (鼠标 / 触控板) 速度与禁用加速的偏好界面.
//  采用程序化 UI: storyboard 中只声明 customClass + 一个空的 visualEffectView 容器,
//  这里在 viewDidLoad 中用 NSStackView 构建全部控件, 比手写 storyboard XML
//  约束更稳, 且与现有 GeneralView 程序化 sync 模式保持一致.
//

import Cocoa

class PreferencesCursorViewController: NSViewController, NSTextFieldDelegate {

    // MARK: 控件

    private let mouseSpeedSlider = NSSlider()
    private let mouseSpeedField = NSTextField()
    private let trackpadSpeedSlider = NSSlider()
    private let trackpadSpeedField = NSTextField()
    private let disableMouseAccCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let affectTrackpadAccCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let resetButton = NSButton(title: "", target: nil, action: nil)

    // 范围
    private let speedMin = 0.25
    private let speedMax = 3.0

    private lazy var speedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = NSNumber(value: speedMin)
        f.maximum = NSNumber(value: speedMax)
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.allowsFloats = true
        return f
    }()

    // 用于 PreferencesTabViewController 计算窗口尺寸的 intrinsic content size
    private var rootStack: NSStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        syncViewWithOptions()
    }

    // MARK: UI 构建

    private func buildUI() {
        // 鼠标分组
        let mouseTitleRow = makeSectionTitle(
            symbol: "computermouse",
            text: NSLocalizedString("Mouse", comment: "Cursor preferences mouse section title")
        )

        let mouseSpeedLabel = NSTextField(labelWithString: NSLocalizedString("Pointer Speed", comment: "Cursor pointer speed slider label"))
        mouseSpeedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mouseSpeedLabel.textColor = .secondaryLabelColor

        configureSpeedSlider(mouseSpeedSlider, action: #selector(mouseSpeedChanged(_:)))
        configureSpeedField(mouseSpeedField, action: #selector(mouseSpeedFieldChanged(_:)))

        let mouseRow = NSStackView(views: [mouseSpeedLabel, mouseSpeedSlider, mouseSpeedField])
        mouseRow.orientation = .horizontal
        mouseRow.spacing = 10
        mouseSpeedLabel.translatesAutoresizingMaskIntoConstraints = false
        mouseSpeedLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        mouseSpeedField.translatesAutoresizingMaskIntoConstraints = false
        mouseSpeedField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        disableMouseAccCheck.title = NSLocalizedString("Disable Mouse Acceleration (Linear)", comment: "Cursor disable mouse acceleration checkbox")
        disableMouseAccCheck.target = self
        disableMouseAccCheck.action = #selector(disableMouseAccChanged(_:))

        // 触控板分组
        let trackpadTitleRow = makeSectionTitle(
            symbol: "rectangle.and.hand.point.up.left",
            text: NSLocalizedString("Trackpad", comment: "Cursor preferences trackpad section title")
        )

        let trackpadSpeedLabel = NSTextField(labelWithString: NSLocalizedString("Pointer Speed", comment: "Cursor pointer speed slider label"))
        trackpadSpeedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trackpadSpeedLabel.textColor = .secondaryLabelColor

        configureSpeedSlider(trackpadSpeedSlider, action: #selector(trackpadSpeedChanged(_:)))
        configureSpeedField(trackpadSpeedField, action: #selector(trackpadSpeedFieldChanged(_:)))

        let trackpadRow = NSStackView(views: [trackpadSpeedLabel, trackpadSpeedSlider, trackpadSpeedField])
        trackpadRow.orientation = .horizontal
        trackpadRow.spacing = 10
        trackpadSpeedLabel.translatesAutoresizingMaskIntoConstraints = false
        trackpadSpeedLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        trackpadSpeedField.translatesAutoresizingMaskIntoConstraints = false
        trackpadSpeedField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        affectTrackpadAccCheck.title = NSLocalizedString("Also Linearize Trackpad (Not Recommended)", comment: "Cursor affect trackpad acceleration checkbox")
        affectTrackpadAccCheck.target = self
        affectTrackpadAccCheck.action = #selector(affectTrackpadAccChanged(_:))

        // 提示
        let hint = NSTextField(labelWithString: NSLocalizedString(
            "Settings apply per-device. Linear mode bypasses macOS pointer acceleration curve.",
            comment: "Cursor preferences description"
        ))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 410

        // 重置按钮
        resetButton.title = NSLocalizedString("Reset to Defaults", comment: "Cursor preferences reset button")
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetClicked(_:))

        let resetRow = NSStackView(views: [NSView(), resetButton])
        resetRow.orientation = .horizontal
        resetRow.distribution = .fill

        let stack = NSStackView(views: [
            mouseTitleRow,
            mouseRow,
            disableMouseAccCheck,
            spacer(height: 8),
            trackpadTitleRow,
            trackpadRow,
            affectTrackpadAccCheck,
            spacer(height: 8),
            hint,
            resetRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 让 row 的 slider 拉满剩余宽度
        mouseRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        trackpadRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        rootStack = stack
    }

    /// 构建 "[图标] 文字" 形式的分组标题. SF Symbols 仅在 macOS 11+ 可用,
    /// 在 10.13/10.14 上 NSImage(systemSymbolName:) 不存在, 所以这里做版本判断,
    /// 老系统降级为纯文字标题, 不影响功能.
    private func makeSectionTitle(symbol: String, text: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: text)
        titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline

        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: img)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: NSFont.systemFontSize, weight: .semibold
            )
            icon.contentTintColor = .secondaryLabelColor
            row.addArrangedSubview(icon)
        }
        row.addArrangedSubview(titleLabel)
        return row
    }

    private func spacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func configureSpeedSlider(_ slider: NSSlider, action: Selector) {
        slider.minValue = speedMin
        slider.maxValue = speedMax
        slider.allowsTickMarkValuesOnly = false
        slider.numberOfTickMarks = 12
        slider.target = self
        slider.action = action
    }

    private func configureSpeedField(_ field: NSTextField, action: Selector) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .right
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.formatter = speedFormatter
        field.target = self
        field.action = action
        // 让失去焦点 (Tab / 点击别处) 也触发 action, 而不只在按 Enter 时触发
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    }

    // MARK: 同步

    private func syncViewWithOptions() {
        let c = Options.shared.cursor
        let mouse = clamp(c.mouseSpeed)
        let trackpad = clamp(c.trackpadSpeed)
        mouseSpeedSlider.doubleValue = mouse
        mouseSpeedField.doubleValue = mouse
        trackpadSpeedSlider.doubleValue = trackpad
        trackpadSpeedField.doubleValue = trackpad
        disableMouseAccCheck.state = c.disableMouseAcceleration ? .on : .off
        affectTrackpadAccCheck.state = c.affectTrackpadAcceleration ? .on : .off
    }

    private func clamp(_ v: Double) -> Double { min(speedMax, max(speedMin, v)) }

    // MARK: 动作

    @objc private func mouseSpeedChanged(_ sender: NSSlider) {
        let v = clamp(sender.doubleValue)
        Options.shared.cursor.mouseSpeed = v
        mouseSpeedField.doubleValue = v
    }

    @objc private func trackpadSpeedChanged(_ sender: NSSlider) {
        let v = clamp(sender.doubleValue)
        Options.shared.cursor.trackpadSpeed = v
        trackpadSpeedField.doubleValue = v
    }

    @objc private func mouseSpeedFieldChanged(_ sender: NSTextField) {
        let v = clamp(sender.doubleValue)
        Options.shared.cursor.mouseSpeed = v
        mouseSpeedSlider.doubleValue = v
        mouseSpeedField.doubleValue = v
    }

    @objc private func trackpadSpeedFieldChanged(_ sender: NSTextField) {
        let v = clamp(sender.doubleValue)
        Options.shared.cursor.trackpadSpeed = v
        trackpadSpeedSlider.doubleValue = v
        trackpadSpeedField.doubleValue = v
    }

    @objc private func disableMouseAccChanged(_ sender: NSButton) {
        Options.shared.cursor.disableMouseAcceleration = (sender.state == .on)
        CursorCore.shared.refreshAccelerationOverride()
    }

    @objc private func affectTrackpadAccChanged(_ sender: NSButton) {
        Options.shared.cursor.affectTrackpadAcceleration = (sender.state == .on)
        CursorCore.shared.refreshAccelerationOverride()
    }

    @objc private func resetClicked(_ sender: NSButton) {
        Options.shared.cursor.mouseSpeed = 1.0
        Options.shared.cursor.trackpadSpeed = 1.0
        Options.shared.cursor.disableMouseAcceleration = false
        Options.shared.cursor.affectTrackpadAcceleration = false
        CursorCore.shared.refreshAccelerationOverride()
        syncViewWithOptions()
    }
}
