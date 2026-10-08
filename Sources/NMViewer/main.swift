import AppKit
import Foundation
import MetalKit
import Noisemaker
import NoisemakerMetalKit

@MainActor
private final class Viewer: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var renderer: NoisemakerViewRenderer?
    private let source: String
    init(source: String) { self.source = source }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let bounds = NSRect(x: 0, y: 0, width: 960, height: 640)
            let window = NSWindow(contentRect: bounds,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Noisemaker"
            window.isReleasedWhenClosed = false
            let view = MTKView(frame: bounds, device: MTLCreateSystemDefaultDevice())
            view.autoresizingMask = [.width, .height]
            view.preferredFramesPerSecond = 60
            window.contentView = view
            let renderer = try NoisemakerViewRenderer(view: view, source: source)
            renderer.onError = { error in
                // The last good graph remains active; surface the diagnostic in the host.
                window.title = "Noisemaker — \(error.localizedDescription)"
                fputs("nm-viewer: \(error)\n", stderr)
            }
            self.renderer = renderer
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("nm-viewer: \(error)\n", stderr)
            exit(1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
@MainActor
private struct Main {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let source: String
            if arguments.isEmpty {
                source = "search synth, filter\nnoise(seed: 1).blur(radiusX: 4, radiusY: 3).write(o0)\nrender(o0)\n"
            } else if arguments.count == 2, arguments[0] == "--dsl" {
                source = try String(contentsOfFile: arguments[1], encoding: .utf8)
            } else {
                fputs("usage: nm-viewer [--dsl program.dsl]\n", stderr)
                exit(2)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = Viewer(source: source)
            application.delegate = delegate
            let menu = NSMenu()
            let item = NSMenuItem()
            menu.addItem(item)
            let applicationMenu = NSMenu()
            applicationMenu.addItem(withTitle: "Quit Noisemaker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = applicationMenu
            application.mainMenu = menu
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            fputs("nm-viewer: \(error)\n", stderr)
            exit(1)
        }
    }
}
