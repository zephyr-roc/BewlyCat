import AppKit
import WebKit

// Use the packaged options page so the request crosses extension contexts.
// The port probe exercises the actual API listener without contacting Bilibili.
@available(macOS 15.4, *)
@MainActor
func checkBackground(in folder: URL) async throws {
    let ext = try await WKWebExtension(resourceBaseURL: folder)
    let controller = WKWebExtensionController(configuration: .nonPersistent())
    let context = WKWebExtensionContext(for: ext)
    context.setPermissionStatus(.grantedExplicitly, for: .storage)
    try controller.load(context)
    defer { try? controller.unload(context) }

    guard let config = context.webViewConfiguration, let options = context.optionsPageURL else {
        throw CheckError("WebKit could not open the packaged options page")
    }
    let page = WKWebView(frame: .zero, configuration: config)
    page.load(URLRequest(url: options))
    repeat { try await Task.sleep(nanoseconds: 100_000_000) } while page.isLoading
    guard page.url == options else { throw CheckError("Extension page failed to load") }

    let probe = """
    const settings = await browser.runtime.sendMessage({type: 'readSettingsStorage'});
    if (settings?.accepted !== true) throw new Error('No reply from readSettingsStorage');
    const port = browser.runtime.connect({name: 'bewly-api-request'});
    return await new Promise((resolve, reject) => {
        port.onDisconnect.addListener(() => reject(new Error('API port disconnected before replying')));
        port.onMessage.addListener(reply => {
            if (reply?.ok === false && reply.error?.message === 'Invalid cancellable API request') resolve(true);
            else reject(new Error('Unexpected reply from API port'));
            port.disconnect();
        });
        port.postMessage({type: 'checkBackgroundConnection'});
    });
    """
    _ = try await page.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .page)
    print("WebKit background replied to runtime.sendMessage and runtime.connect")
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        guard #available(macOS 15.4, *) else { throw CheckError("Requires macOS 15.4 or later") }
        try await checkBackground(in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        exit(0)
    } catch {
        fputs("WebKit check failed: \(error as NSError)\n", stderr)
        exit(1)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    fputs("Timed out waiting for WebKit background messaging\n", stderr)
    exit(1)
}
app.run()
