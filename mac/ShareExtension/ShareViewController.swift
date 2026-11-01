import AppKit
import UniformTypeIdentifiers

/// Finder supplies file URLs. Launch Services hands them to the containing app;
/// the extension never reads MiDrop's credentials or sends a transfer itself.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let status = NSTextField(wrappingLabelWithString: "正在将文件交给 MiDrop…")
    private var started = false
    private var finished = false
    private var scopedURLs: [URL] = []

    override func loadView() {
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelShare))
        let stack = NSStackView(views: [status, cancel])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 130)
        view = stack
        preferredContentSize = NSSize(width: 320, height: 130)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 1000,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            status.stringValue = "请选择 1–1000 个文件，再共享到 MiDrop。"
            return
        }
        // Keep the original selection order, and reject the whole batch if one
        // provider fails instead of silently sending only some selected files.
        let group = DispatchGroup()
        var urls = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls[index] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !self.finished else { return }
            let files = urls.compactMap { $0 }
            guard files.count == providers.count else {
                self.status.stringValue = "无法读取选中的文件，请在 Finder 中重新选择后共享。"
                return
            }
            self.openMiDrop(files)
        }
    }

    private func openMiDrop(_ urls: [URL]) {
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        // Resolve our own containing app, including when running from a custom
        // build directory; don't accidentally launch another installed version.
        let app = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.releaseAccess()
                if let error {
                    NSLog("MiDrop share handoff failed for %@: %@", app.path, String(reflecting: error))
                    self.status.stringValue = "无法打开 MiDrop：\(error.localizedDescription)"
                } else if !self.finished {
                    self.finished = true
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
    }

    private func releaseAccess() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    @objc private func cancelShare() {
        finished = true
        releaseAccess()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
