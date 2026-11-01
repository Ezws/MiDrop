import AppKit
import UniformTypeIdentifiers

/// Launch Services hands shared files or a text draft to the containing app.
/// The extension never reads credentials or sends a transfer itself.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let status = NSTextField(wrappingLabelWithString: "正在交给 MiDrop…")
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
        guard !providers.isEmpty, providers.count <= 1000 else {
            status.stringValue = "请选择文件、文字或链接，再共享到 MiDrop。"
            return
        }
        if !providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            loadTexts(providers); return
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

    private func loadTexts(_ providers: [NSItemProvider]) {
        guard providers.allSatisfy({ !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && ($0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)) }) else {
            status.stringValue="请分别共享文件或文字，暂不支持混合选择。"; return
        }
        let group=DispatchGroup()
        var values=[String?](repeating:nil,count:providers.count)
        for (index,provider) in providers.enumerated() {
            group.enter()
            let type=provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
            provider.loadItem(forTypeIdentifier:type,options:nil) { item,_ in
                let value=(item as? URL)?.absoluteString ?? (item as? String)
                    ?? (item as? Data).flatMap { String(data:$0,encoding:.utf8) }
                DispatchQueue.main.async { values[index]=value; group.leave() }
            }
        }
        group.notify(queue:.main) { [weak self] in
            guard let self, !self.finished else { return }
            let texts=values.compactMap { $0 }
            let text=texts.joined(separator:"\n")
            guard texts.count==providers.count, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count<=65536 else {
                self.status.stringValue="无法读取文字，或内容超过 64 KiB。请缩短后重试。"; return
            }
            var components=URLComponents(); components.scheme="midrop"; components.host="share-text"
            components.queryItems=[URLQueryItem(name:"text",value:text)]
            guard let url=components.url else { self.status.stringValue="无法共享这段文字。"; return }
            self.openMiDrop([url])
        }
    }

    private func openMiDrop(_ urls: [URL]) {
        scopedURLs = urls.filter { $0.isFileURL && $0.startAccessingSecurityScopedResource() }
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
