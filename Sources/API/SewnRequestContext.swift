import Hummingbird
import NIOCore
import RaoStack

/// Custom request context for Sewn.
///
/// - Stores auth fields populated by `AuthMiddleware` / `AdminMiddleware`
///   (replaces the Vapor `Request.storage` extension pattern), including
///   `isLocalOnly` for the on-device lane a local app reaches with no account.
/// - Stores the calling app populated by `StackSecretMiddleware`, which every
///   Thread fan-out is scoped by on a shared stack.
/// - Overrides the 2 MB default `maxUploadSize` to 100 MB for large
///   embedding / document payloads.
/// - Conforms to `RemoteAddressRequestContext` so middleware can inspect
///   the client's socket address via `context.remoteAddress`.
struct SewnRequestContext: RequestContext, RemoteAddressRequestContext, StackCallerRequestContext {
    var coreContext: CoreRequestContextStorage

    // MARK: - Remote address (captured at init from the NIO channel)

    var remoteAddress: SocketAddress?

    // MARK: - Auth (populated by AuthMiddleware / AdminMiddleware)

    var authUserId: String?
    var authToken: String?
    var authDisplayName: String?
    /// True when AuthMiddleware admitted this request without a bearer: a
    /// caller the stack secret named (loopback, secret verified) running the
    /// on-device lane with no account. `authUserId` is then
    /// `LocalOnlyGrant.ownerId(for: callerApp)` and `authToken` is nil. Every
    /// generation route refuses a hosted provider for such a caller.
    var isLocalOnly: Bool = false

    // MARK: - Stack (populated by StackSecretMiddleware)

    /// The app whose stack secret this request carried. Nil on an open server.
    var callerApp: RaoApp?

    // MARK: - Init

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }

    // MARK: - Upload limit

    var maxUploadSize: Int { 100 * 1_024 * 1_024 }
}
