import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let info = try NSDictionary(contentsOf: app.appendingPathComponent("Contents/PlugIns/MiDropShare.appex/Contents/Info.plist"), error: ())
let config = info["NSExtension"] as! [String: Any]
let attributes = config["NSExtensionAttributes"] as! [String: Any]
let predicate = NSPredicate(format: attributes["NSExtensionActivationRule"] as! String)
func matches(_ types: [[String]]) -> Bool {
    predicate.evaluate(with: ["extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]])
}
check(matches([["public.file-url"]]), "Finder file URL must activate extension")
check(matches([["public.file-url", "public.jpeg"], ["public.file-url", "public.data"]]), "Mixed file types must activate extension")
check(!matches([]), "Empty selection must not activate extension")
check(!matches([["public.url"]]), "Web links must not activate extension")
check(!matches([["public.plain-text"]]), "Plain text must not activate extension")
check(!matches([["public.file-url"], ["public.url"]]), "Unsupported item must reject whole selection")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("midrop-share-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let files = ["中文 image.png", "archive.zip", "empty.bin"].map { directory.appendingPathComponent($0) }
for url in files { try Data().write(to: url) }
// Exercise the system registry as well as the activation predicate. The app
// must have been opened and its sharing extension enabled before this check.
for selection in files.map({ [$0 as NSURL] }) + [files.map { $0 as NSURL }] {
    let services = NSSharingService.sharingServices(forItems: selection)
    check(services.contains { $0.title == "MiDrop" && $0.canPerform(withItems: selection) },
          "System sharing registry must offer MiDrop for \(selection.count) file(s); open the app and enable its extension first")
}
print("PASS: activation rules and system discovery for image, archive, binary and multiple files")
