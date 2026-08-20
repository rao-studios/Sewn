import Conduit

/// Routes Conduit's gRPC session/client logs through SeerLogger so the
/// structured Cockpit JSON lines (service label "Seer") keep flowing.
struct SeerConduitLogger: ConduitLogger {
    let base: SeerLogger

    func debug(_ label: String?, _ message: String)   { base.debug(label, "\(message)", service: .seer) }
    func info(_ label: String?, _ message: String)    { base.info(label, "\(message)", service: .seer) }
    func warning(_ label: String?, _ message: String) { base.warning(label: label, "\(message)", service: .seer) }
    func error(_ label: String?, _ message: String)   { base.error(label, "\(message)", service: .seer) }
}
