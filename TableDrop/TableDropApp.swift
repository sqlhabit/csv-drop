import AppKit
import SwiftUI

@main
struct TableDropApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowMovableConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 420)
    }
}

private struct WindowMovableConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MovableWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = true
    }
}

private final class MovableWindowView: NSView {
    private var clickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isMovableByWindowBackground = true

        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.resignFocusIfClickingOutsideTextField(event)
            return event
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    private func resignFocusIfClickingOutsideTextField(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
        guard let hitView = window.contentView?.hitTest(point) else {
            window.makeFirstResponder(nil)
            return
        }
        if !isTextInputView(hitView) {
            window.makeFirstResponder(nil)
        }
    }

    private func isTextInputView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view is NSTextField || view is NSTextView {
                return true
            }
            current = view.superview
        }
        return false
    }
}
