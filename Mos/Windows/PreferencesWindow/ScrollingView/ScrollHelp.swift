//
//  ScrollHelp.swift
//  Mos
//  滚动 / hold-scroll 帮助 popover 共用工具.
//  - makeSectionHeader: sheet 用的「标题 + ? 按钮」一行
//  - showOrTogglePopover: 点 ? 弹 popover, 再点关掉; 把帮助内容挂在 button 上
//

import Cocoa
import ObjectiveC

enum ScrollHelp {

    /// sheet section 用: 加粗标题 + 右侧圆 ? 按钮.
    /// target/action 必须实现并在 handler 内调用 `showOrTogglePopover`.
    static func makeSectionHeader(
        title: String,
        helpTitle: String,
        helpBody: String,
        target: AnyObject,
        action: Selector
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        let helpButton = makeHelpButton(helpTitle: helpTitle, helpBody: helpBody,
                                        target: target, action: action)

        let row = NSStackView(views: [label, helpButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// 程序化构造一个 ? 按钮, 把 helpTitle / helpBody 挂到按钮上.
    static func makeHelpButton(
        helpTitle: String,
        helpBody: String,
        target: AnyObject,
        action: Selector
    ) -> NSButton {
        let btn = NSButton(title: "", target: target, action: action)
        btn.bezelStyle = .helpButton
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.helpTitle = helpTitle
        btn.helpBody = helpBody
        return btn
    }

    /// 给 storyboard 里已存在的 helpButton 挂帮助内容 (call once in viewDidLoad).
    static func attachHelp(_ button: NSButton, title: String, body: String) {
        button.helpTitle = title
        button.helpBody = body
    }

    /// 点 ? 时调用. 如果当前已经弹了, 关掉; 否则弹一个新的.
    /// 返回新的 popover (或 nil 表示已关闭), 调用方负责持有引用.
    static func showOrTogglePopover(from button: NSButton, current: NSPopover?) -> NSPopover? {
        if let existing = current, existing.isShown {
            existing.performClose(nil)
            return nil
        }
        let title = button.helpTitle ?? ""
        let body = button.helpBody ?? ""
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makePopoverContentVC(title: title, body: body)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        return popover
    }

    // MARK: - Private

    private static func makePopoverContentVC(title: String, body: String) -> NSViewController {
        let vc = NSViewController()
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        bodyLabel.textColor = .labelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.preferredMaxLayoutWidth = 320

        container.addSubview(titleLabel)
        container.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bodyLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            bodyLabel.widthAnchor.constraint(equalToConstant: 320),
        ])
        vc.view = container
        return vc
    }
}

// MARK: - NSButton + help payload

/// 把帮助 popover 的标题/正文挂在 ? 按钮上, 点击时取回.
private var helpTitleKey: UInt8 = 0
private var helpBodyKey: UInt8 = 0

extension NSButton {
    var helpTitle: String? {
        get { objc_getAssociatedObject(self, &helpTitleKey) as? String }
        set { objc_setAssociatedObject(self, &helpTitleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var helpBody: String? {
        get { objc_getAssociatedObject(self, &helpBodyKey) as? String }
        set { objc_setAssociatedObject(self, &helpBodyKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
