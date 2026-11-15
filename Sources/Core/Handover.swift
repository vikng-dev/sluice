import Foundation
import Network
import notify

/// One copy serves at a time, and a new one takes the port without an answer being cut: it asks for the
/// port, the copy that holds it stops listening and finishes the answers it is giving, then leaves. Two
/// cannot listen at once, so for the moment between them a client is refused and connects again.
public enum Handover {
    private static let name = "\(Sluice.id).handover"
    /// How long a copy that let go of the port may take over its answers; one that never ends would keep it for good.
    static let patience: TimeInterval = 1800

    /// Starts the server `make` gives on its port, having asked a copy that holds the port to let go of
    /// it. From then on it lets go itself when another asks: `yielded` is told, and the process ends once
    /// its answers have, or the copy that took over is gone and clients are left with nothing.
    public static func start(_ make: () throws -> Server, yielded: @escaping @Sendable () -> Void) async throws -> Server {
        var server = try make()
        // A copy that holds the port lets go within its next turn; one that does not is no Sluice that hands over.
        let asked = Date()
        while true {
            do {
                try await server.start()
                break
            } catch NWError.posix(.EADDRINUSE) where Date().timeIntervalSince(asked) < 5 {
                ask()
                try await Task.sleep(for: .milliseconds(20))
                server = try make()
            }
        }
        var token: Int32 = 0
        let held = server
        let status = notify_register_dispatch(name, &token, .global()) { token in
            var asker: UInt64 = 0
            notify_get_state(token, &asker)
            let successor = pid_t(asker)
            guard successor != getpid() else { return }
            notify_cancel(token)
            yielded()
            let until = Date().addingTimeInterval(patience)
            Task {
                await held.drain { Date() > until || kill(successor, 0) != 0 }
                exit(0)
            }
        }
        // The system's notifications are there for every process; without them it could never let go.
        precondition(status == NOTIFY_STATUS_OK, "could not listen for a handover: notify status \(status)")
        return server
    }

    /// Says that this process wants the port. One that cannot say so does not get the port, and that is what is thrown.
    private static func ask() {
        var token: Int32 = 0
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, UInt64(getpid()))
        notify_post(name)
        notify_cancel(token)
    }
}
