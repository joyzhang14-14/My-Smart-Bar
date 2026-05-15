//
//  CustomAppIconManager.swift
//  boringNotch
//
//  让用户上传自定义图标，自动居中裁剪 + 缩放 + 套 macOS Big Sur squircle 模板。
//  仅运行时生效（NSApp.applicationIconImage），不修改 .app bundle 本身。
//
//  算法对照：参考 My-Orphies 项目的 squareCropResize（React + Canvas 版）。
//

import AppKit
import Defaults
import UniformTypeIdentifiers

@MainActor
final class CustomAppIconManager: ObservableObject {
    static let shared = CustomAppIconManager()

    /// macOS Big Sur+ icon template constants
    private static let canvasSize: CGFloat = 1024
    private static let bodyRatio: CGFloat = 824.0 / 1024.0   // squircle 占 80.5%
    private static let cornerRatio: CGFloat = 0.225          // 圆角 = 实体边长 × 22.5%

    @Published private(set) var currentCustomIcon: NSImage?

    private init() {
        if Defaults[.customAppIconEnabled], let img = loadFromDisk() {
            currentCustomIcon = img
        }
    }

    /// 应用启动时调用：如果用户之前设过自定义图标，恢复它。
    func applyOnLaunchIfEnabled() {
        guard Defaults[.customAppIconEnabled], let img = currentCustomIcon ?? loadFromDisk() else { return }
        currentCustomIcon = img
        NSApp.applicationIconImage = img
    }

    /// 弹文件选择器，选完自动处理 + 应用 + 持久化。返回是否成功。
    @discardableResult
    func pickAndApply() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose an image for the app icon"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]

        guard panel.runModal() == .OK, let url = panel.url, let source = NSImage(contentsOf: url) else {
            return false
        }

        guard let processed = processIcon(source) else { return false }
        guard saveToDisk(processed) else { return false }

        Defaults[.customAppIconEnabled] = true
        currentCustomIcon = processed
        NSApp.applicationIconImage = processed
        return true
    }

    /// 恢复 .app bundle 内置图标。
    func reset() {
        Defaults[.customAppIconEnabled] = false
        currentCustomIcon = nil
        try? FileManager.default.removeItem(at: storageURL)
        // 传 nil 让系统回到 bundle 默认图标
        NSApp.applicationIconImage = nil
    }

    // MARK: - Private

    /// Application Support/<bundleID>/CustomAppIcon.png
    private var storageURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "MySmartBar",
                                              isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("CustomAppIcon.png")
    }

    private func loadFromDisk() -> NSImage? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        return NSImage(contentsOf: storageURL)
    }

    @discardableResult
    private func saveToDisk(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: storageURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 居中裁剪正方形 → 缩放到 1024 → 套 squircle 蒙版（80.5% 居中 + 透明 padding）。
    private func processIcon(_ source: NSImage) -> NSImage? {
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        // 取较短边为正方形原始裁剪区域
        let side = min(srcSize.width, srcSize.height)
        let srcRect = NSRect(
            x: (srcSize.width - side) / 2,
            y: (srcSize.height - side) / 2,
            width: side, height: side
        )

        let canvas = Self.canvasSize
        let bodySize = canvas * Self.bodyRatio
        let offset = (canvas - bodySize) / 2
        let cornerRadius = bodySize * Self.cornerRatio

        let result = NSImage(size: NSSize(width: canvas, height: canvas))
        result.lockFocus()
        defer { result.unlockFocus() }

        guard let ctx = NSGraphicsContext.current else { return nil }
        ctx.imageInterpolation = .high

        let bodyRect = NSRect(x: offset, y: offset, width: bodySize, height: bodySize)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()

        source.draw(in: bodyRect, from: srcRect, operation: .sourceOver, fraction: 1.0)

        return result
    }
}
