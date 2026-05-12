//
//  HoldScrollBindingsWindowController.swift
//  Mos
//  自定义「按住触发键 + 滚动 → 模拟键盘按键」绑定的管理 sheet.
//  与 dash/toggle/block 三个固定 hold-scroll 热键平行, 但允许用户增删任意条数.
//  支持全局编辑 (Options.shared.scroll.holdScrollBindings) 和每应用编辑
//  (Application.scroll.holdScrollBindings) 两种数据源.
//

import Cocoa

class HoldScrollBindingsWindowController: NSWindowController {

    // MARK: - 数据源 (闭包抽象, 让视图与存储解耦)

    private let readBindings: () -> [HoldScrollBinding]
    private let writeBindings: ([HoldScrollBinding]) -> Void
    private let titleSuffix: String?  // per-app 时显示应用名

    // MARK: - 录键上下文

    private enum RecordingTarget {
        case newBindingTrigger
        case existingBindingField(id: UUID, field: Field)
    }
    private enum Field { case trigger, up, down }
    private var recordingTarget: RecordingTarget?
    private let triggerRecorder = KeyRecorder()
    private let keystrokeRecorder = KeyRecorder()

    // MARK: - UI

    private let rowsStack = NSStackView()
    private var helpPopover: NSPopover?

    // MARK: - 初始化

    /// 编辑全局
    convenience init() {
        self.init(read: { Options.shared.scroll.holdScrollBindings },
                  write: { Options.shared.scroll.holdScrollBindings = $0 },
                  titleSuffix: nil)
    }

    /// 编辑某个应用的 per-app 设置
    convenience init(application: Application) {
        let name = (application.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        self.init(read: { application.scroll.holdScrollBindings },
                  write: { application.scroll.holdScrollBindings = $0 },
                  titleSuffix: name)
    }

    private init(
        read: @escaping () -> [HoldScrollBinding],
        write: @escaping ([HoldScrollBinding]) -> Void,
        titleSuffix: String?
    ) {
        self.readBindings = read
        self.writeBindings = write
        self.titleSuffix = titleSuffix
        super.init(window: nil)
        triggerRecorder.delegate = self
        keystrokeRecorder.delegate = self
        buildWindow()
        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    // MARK: - 窗口构建

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let baseTitle = NSLocalizedString("Manage Hold-Scroll Shortcuts", comment: "Hold-scroll bindings sheet title")
        win.title = titleSuffix.map { "\(baseTitle) — \($0)" } ?? baseTitle
        win.isReleasedWhenClosed = false
        self.window = win

        let content = NSView()
        win.contentView = content

        // 标题行 + ? 按钮
        let titleRow = ScrollHelp.makeSectionHeader(
            title: NSLocalizedString("Hold-Scroll Bindings", comment: "Sheet section: bindings"),
            helpTitle: NSLocalizedString("Hold-Scroll Bindings", comment: "Help popover title: bindings"),
            helpBody: NSLocalizedString(
                "Hold the trigger key (e.g. mouse4) and scroll the wheel — Mos will emit the keystrokes you set, instead of scrolling.\n\nUse it for things like Photoshop brush size ([ / ]), zooming, or any per-app shortcut your hardware can't bind natively.\n\nDirection follows your system Natural Scrolling setting — if it feels reversed, swap the two keystroke fields.",
                comment: "Help body: bindings"
            ),
            target: self,
            action: #selector(helpButtonClicked(_:))
        )

        // 行容器 (放进 NSScrollView, binding 数量多时能滚)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = NSScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .lineBorder
        listScroll.documentView = rowsStack

        let addButton = NSButton(title: NSLocalizedString("+ Add", comment: "Hold-scroll add binding"),
                                 target: self, action: #selector(addClicked(_:)))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: NSLocalizedString("Done", comment: "Hold-scroll done"),
                                  target: self, action: #selector(doneClicked(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleRow)
        content.addSubview(listScroll)
        content.addSubview(addButton)
        content.addSubview(doneButton)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            listScroll.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            listScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            listScroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            rowsStack.widthAnchor.constraint(equalTo: listScroll.widthAnchor, constant: -4),
            rowsStack.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 4),
        ])
    }

    @objc private func helpButtonClicked(_ sender: NSButton) {
        helpPopover = ScrollHelp.showOrTogglePopover(from: sender, current: helpPopover)
    }

    // MARK: - 行渲染

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bindings = readBindings()
        rowsStack.addArrangedSubview(makeHeaderRow())
        if bindings.isEmpty {
            let empty = NSTextField(labelWithString: NSLocalizedString(
                "No bindings yet. Click + Add to create one.",
                comment: "Hold-scroll empty state"
            ))
            empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            empty.textColor = .tertiaryLabelColor
            rowsStack.addArrangedSubview(empty)
            return
        }
        for binding in bindings {
            rowsStack.addArrangedSubview(makeRow(binding))
        }
    }

    private func makeHeaderRow() -> NSView {
        let trigger = makeHeaderLabel(NSLocalizedString("Trigger", comment: "Hold-scroll col: trigger"))
        let up = makeHeaderLabel(NSLocalizedString("Scroll Up →", comment: "Hold-scroll col: up"))
        let down = makeHeaderLabel(NSLocalizedString("Scroll Down →", comment: "Hold-scroll col: down"))
        let trailing = NSView()
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let row = NSStackView(views: [trigger, up, down, trailing])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeRow(_ binding: HoldScrollBinding) -> NSView {
        let triggerBtn = makeFieldButton(text: binding.trigger.displayName)
        triggerBtn.target = self
        triggerBtn.action = #selector(recordTriggerInRow(_:))
        triggerBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: binding.id.uuidString)

        let upBtn = makeFieldButton(text: binding.upKeystroke?.displayComponents.joined(separator: " ")
                                     ?? NSLocalizedString("(none)", comment: "Hold-scroll empty keystroke"))
        upBtn.target = self
        upBtn.action = #selector(recordUpInRow(_:))
        upBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: binding.id.uuidString)

        let downBtn = makeFieldButton(text: binding.downKeystroke?.displayComponents.joined(separator: " ")
                                       ?? NSLocalizedString("(none)", comment: "Hold-scroll empty keystroke"))
        downBtn.target = self
        downBtn.action = #selector(recordDownInRow(_:))
        downBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: binding.id.uuidString)

        let removeBtn = NSButton(title: "✕", target: self, action: #selector(removeRow(_:)))
        removeBtn.bezelStyle = .inline
        removeBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: binding.id.uuidString)
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let row = NSStackView(views: [triggerBtn, upBtn, downBtn, removeBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeFieldButton(text: String) -> NSButton {
        let btn = NSButton(title: text, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    // MARK: - 增删 actions

    @objc private func addClicked(_ sender: NSButton) {
        recordingTarget = .newBindingTrigger
        triggerRecorder.startRecording(from: sender, mode: .singleKey)
    }

    @objc private func doneClicked(_ sender: NSButton) {
        guard let win = window else { return }
        if let parent = win.sheetParent {
            parent.endSheet(win)
        } else {
            win.close()
        }
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard let id = bindingIdFromSender(sender) else { return }
        var bindings = readBindings()
        bindings.removeAll { $0.id == id }
        writeBindings(bindings)
        rebuildRows()
    }

    @objc private func recordTriggerInRow(_ sender: NSButton) {
        guard let id = bindingIdFromSender(sender) else { return }
        recordingTarget = .existingBindingField(id: id, field: .trigger)
        triggerRecorder.startRecording(from: sender, mode: .singleKey)
    }

    @objc private func recordUpInRow(_ sender: NSButton) {
        guard let id = bindingIdFromSender(sender) else { return }
        recordingTarget = .existingBindingField(id: id, field: .up)
        keystrokeRecorder.startRecording(from: sender, mode: .adaptive)
    }

    @objc private func recordDownInRow(_ sender: NSButton) {
        guard let id = bindingIdFromSender(sender) else { return }
        recordingTarget = .existingBindingField(id: id, field: .down)
        keystrokeRecorder.startRecording(from: sender, mode: .adaptive)
    }

    private func bindingIdFromSender(_ sender: NSButton) -> UUID? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - KeyRecorderDelegate

extension HoldScrollBindingsWindowController: KeyRecorderDelegate {
    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: InputEvent, isDuplicate: Bool) {
        defer { recordingTarget = nil }
        guard let target = recordingTarget else { return }
        var bindings = readBindings()
        let trigger = ScrollHotkey(type: event.type, code: event.code)
        switch target {
        case .newBindingTrigger:
            bindings.append(HoldScrollBinding(trigger: trigger))
        case .existingBindingField(let id, let field):
            guard let idx = bindings.firstIndex(where: { $0.id == id }) else { return }
            switch field {
            case .trigger: bindings[idx].trigger = trigger
            case .up:      bindings[idx].upKeystroke = RecordedEvent(from: event)
            case .down:    bindings[idx].downKeystroke = RecordedEvent(from: event)
            }
        }
        writeBindings(bindings)
        rebuildRows()
    }
}
