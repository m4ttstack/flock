import Foundation

/// The one line a machine profile's window shows about its connection, and
/// the button that goes with it when there is one.
struct MachineNotice {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let text: String
    var action: Action?
}
