import AppKit

// `Glideball --mcp`: an AI app started this as its helper (AIAppsHelper.swift). It only
// passes messages to the running Glideball, so it leaves before anything of AppKit, the
// settings or the trackball is touched, and never comes back.
if AIAppsHelper.isAsked { AIAppsHelper.run() }

// `--render-ui <dir>` and `--self-test` run with nothing live (Sandbox.swift);
// this must come before anything reads settings.
Sandbox.enter()

let app = NSApplication.shared
switch Sandbox.mode {
case .renderUI?:
    MainActor.assumeIsolated { RenderUI.start() }   // draws every screen offscreen, then exits
case .selfTest?:
    MainActor.assumeIsolated { SelfTest.start() }   // the real launch path, sandboxed, then exits
case .scrollBench?:
    MainActor.assumeIsolated { ScrollBench.start() }   // times fast scrolling of every page offscreen, then exits
case nil:
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
