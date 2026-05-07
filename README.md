<p align="center">
  <img width="240" src="https://github.com/Caldis/Mos/blob/master/dmg/dmg-icon.png?raw=true">
</p>

# MyMos

> **基于 [Caldis/Mos](https://github.com/Caldis/Mos) 的个人衍生版**，在原版基础上加了**鼠标 / 触控板独立指针速度调节**和**禁用鼠标加速（线性映射）**功能。
>
> 滚动平滑、按键绑定、Logi 集成、每应用例外、快捷键、所有原版能力**一个不少**。

[English](#english) | 中文

---

## 与原版的区别

原版 Mos 只处理滚轮，**不调指针速度也不绕过加速曲线**。这个 fork 加了一个新的「速度」标签页，能：

| 功能 | 原版 Mos | MyMos |
|------|:---:|:---:|
| 平滑滚轮 | ✅ | ✅ |
| 反向滚轮 / 按应用例外 / Logi 集成 / 快捷键 | ✅ | ✅ |
| **鼠标指针速度独立调节** | ❌ | ✅ |
| **触控板指针速度独立调节** | ❌ | ✅ |
| **禁用鼠标加速（线性映射）** | ❌ | ✅ |

实现方式：在 `Mos/CursorCore/` 新增三个模块——

- **PointingDeviceRegistry**：用 IOHIDManager 跟踪所有指针设备，按 `kCGMouseEventInstanceUserData` 区分鼠标 / 触控板
- **CursorCore (L1)**：CGEventTap 拦截 `mouseMoved` / `mouseDragged`，按设备类别施加不同速度倍率
- **LinearPointerSynthesizer (L2)**：勾选"禁用加速"时，从 IOHIDManager 取原始 HID delta 自行合成线性事件，绕开系统加速曲线

L1 与 L2 完全和原版的 ScrollCore / ButtonCore / Logi 等模块解耦，**不修改任何原版逻辑**。

## 安装

需要 Xcode 16+ 自行编译：

```bash
git clone https://github.com/foogooooooo/MyMos.git
cd MyMos
open Mos.xcodeproj
# Xcode 自动解析 SPM 依赖（Charts、LoginServiceKit）
# ⌘ + R 编译运行
```

首次运行需在「系统设置 → 隐私与安全 → 辅助功能」授权。

## 使用

状态栏图标 → 偏好设置 → **速度** 标签：

- **鼠标**：拖滑杆或直接输入数值（0.25× ～ 3.0×）调指针速度
- **禁用鼠标加速（线性）**：勾选后绕过 macOS 自带加速曲线
- **触控板**：单独调速度（默认不动加速曲线，避免破坏触控手势）

## 致谢

**所有的滚动平滑算法、按键架构、Logi 集成、本地化、UI 框架，全部来自原作者 [@Caldis](https://github.com/Caldis) 的 [Mos](https://github.com/Caldis/Mos) 项目。** 这个 fork 只是在他的肩膀上多搭了一层指针速度模块，**核心价值仍然 100% 归原作者**。

如果你喜欢这个 fork 的功能，请优先去 [原项目仓库](https://github.com/Caldis/Mos) star / 赞助 / 致谢原作者。

## 协议

继承原项目的 [Creative Commons BY-NC 4.0](./LICENSE) 协议：
- 必须保留原作者署名
- 禁止商业用途
- 衍生作品须明确标注修改内容（本 README 已说明）

---

## English

This is a personal derivative of [Caldis/Mos](https://github.com/Caldis/Mos) that adds:

- Independent pointer speed adjustment for mouse and trackpad
- Disable mouse acceleration (linear pointer mapping, bypasses macOS acceleration curve)

All credit for the original scroll smoothing engine, button system, Logi integration, and UI framework belongs to [@Caldis](https://github.com/Caldis). This fork only adds a new "Speed" preferences tab built on top of the existing architecture in `Mos/CursorCore/`.

Licensed under CC BY-NC 4.0 — same as upstream. Attribution required, non-commercial use only.
