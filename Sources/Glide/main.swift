import AppKit

// `--render-ui <dir>` and `--self-test` run with nothing live (Sandbox.swift);
// this must come before anything reads settings.
Sandbox.enter()

let app = NSApplication.shared
switch Sandbox.mode {
case .renderUI?:
    MainActor.assumeIsolated { RenderUI.start() }   // draws every screen offscreen, then exits
case .selfTest?:
    MainActor.assumeIsolated { SelfTest.start() }   // the real launch path, sandboxed, then exits
case nil:
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
