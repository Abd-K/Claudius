import SwiftUI

@main
struct ClaudiusApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var pin = PinController()
    @StateObject private var sessions = SessionsModel()

    var body: some Scene {
        // Real window + Dock icon — open it from the Dock like any app.
        Window("Claude usage", id: "main") {
            PopoverView(model: model, pin: pin, sessions: sessions)
                .onAppear { pin.configure(model) }
        }
        .windowResizability(.contentSize)

        // Menu bar item stays, for the at-a-glance dot.
        MenuBarExtra {
            PopoverView(model: model, pin: pin, sessions: sessions)
                .onAppear { pin.configure(model) }
        } label: {
            MenuLabelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
