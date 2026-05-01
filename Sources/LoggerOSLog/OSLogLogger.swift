import Foundation
import Loggers
import os

/// A `Logger` that forwards entries to Apple's unified logging system
/// via [`os.Logger`](https://developer.apple.com/documentation/os/logger).
///
/// `OSLogLogger` is the universal, transport-neutral OSLog adapter:
/// it accepts the record-based `Logger` contract, applies the lazy
/// drop guard, renders the entry as privacy-safe text via
/// `LogMessage.redactedDescription` and `LogAttribute.redactedDescription`,
/// and emits a single line per entry through `os.Logger`.
///
/// ## Privacy
///
/// `OSLogLogger` does **not** reconstruct an `OSLogMessage` with
/// per-segment privacy from runtime `LogSegment` arrays --
/// `OSLogMessage` is a compile-time construct that the system builds
/// from Swift string interpolation, and it cannot be assembled
/// reliably from dynamic data. Runtime privacy is enforced before the
/// string reaches `os.Logger`: segments and attributes marked
/// `.private` are replaced with `<private>` and `.sensitive` ones with
/// `<redacted>` by `redactedDescription`. The redacted string is then
/// passed into `os.Logger` with a compile-time
/// `\(text, privacy: .public)` interpolation, which is safe because
/// the sensitive data has already been removed.
///
/// True OSLog interpolation privacy (`%{public}s` / `%{private}s` /
/// `%{sensitive}s`) is available only by using Apple's `os.Logger`
/// directly with a literal interpolation; that path is intentionally
/// outside the universal `Logger` contract.
///
/// ## Mapping
///
/// - `LoggerDomain` -> OSLog `category`
/// - `LoggerLevel` -> `OSLogType` per the seven-severity model:
///   - `trace`    -> `.debug`
///   - `debug`    -> `.debug`
///   - `info`     -> `.info`
///   - `notice`   -> `.default`
///   - `warning`  -> `.default`
///   - `error`    -> `.error`
///   - `critical` -> `.fault`
/// - `LogMessage` and `LogAttribute` -> a single privacy-safe
///   text line, formatted as `<message>` or `<message> {key=value, ...}`
///
/// ## Filtering
///
/// `OSLogLogger` drops an entry without evaluating `message`,
/// `attributes`, or any underlying `os.Logger` when either of the
/// following is true:
///
/// - `level == .disabled`
/// - the severity of `level` is below ``minimumLevel``
public struct OSLogLogger: Loggers.Logger {
    /// A severity threshold for ``OSLogLogger``.
    ///
    /// `MinimumLevel` is intentionally severity-only and does not
    /// include a `disabled` case: per the `LoggerLevel` contract,
    /// `disabled` is a per-message sentinel and must not be used as a
    /// threshold value. To turn off logging entirely, use a logger
    /// that drops every entry instead of configuring a threshold.
    public enum MinimumLevel: CaseIterable, Sendable {
        /// The most detailed severity, intended for fine-grained
        /// tracing.
        case trace

        /// A detailed severity intended for debugging.
        case debug

        /// An informational severity describing normal operation.
        case info

        /// A normal but significant severity worth surfacing above
        /// everyday `info` traffic.
        case notice

        /// A severity for potential issues that do not yet stop
        /// execution.
        case warning

        /// A severity for error conditions that require attention.
        case error

        /// A severity for severe conditions that require immediate
        /// attention.
        case critical

        /// The default minimum severity used when none is specified.
        ///
        /// Equal to ``MinimumLevel/warning``.
        public static let defaultLevel = MinimumLevel.warning
    }

    /// The OSLog subsystem under which every entry is logged. Each
    /// entry's `LoggerDomain` becomes the `category`.
    public let subsystem: String

    /// The minimum severity that this logger emits. Entries whose
    /// severity is strictly lower are dropped without evaluating the
    /// message or attributes.
    public let minimumLevel: MinimumLevel

    /// The sink that receives the resolved entry. Defaults to a
    /// closure that constructs an `os.Logger` per category and emits
    /// the redacted text with `\(text, privacy: .public)` so the
    /// runtime payload is preserved verbatim.
    private let emit: @Sendable (LoggerDomain, OSLogType, String) -> Void

    /// Creates an `OSLogLogger` that emits via Apple's unified
    /// logging system.
    ///
    /// - Parameters:
    ///   - subsystem: The `subsystem` passed to `os.Logger`. Typically
    ///     a reverse-DNS identifier such as `"com.company.app"`.
    ///   - minimumLevel: The minimum severity to emit. Defaults to
    ///     ``MinimumLevel/defaultLevel``.
    public init(
        subsystem: String,
        minimumLevel: MinimumLevel = .defaultLevel
    ) {
        let cache = OSLoggerCache(subsystem: subsystem)
        self.init(
            subsystem: subsystem,
            minimumLevel: minimumLevel,
            emit: { domain, level, text in
                cache.logger(for: domain)
                    .log(level: level, "\(text, privacy: .public)")
            }
        )
    }

    /// Creates an `OSLogLogger` with a custom emit sink. This
    /// initializer is internal so production callers cannot depend on
    /// a private seam, while test targets can reach it via
    /// `@testable import LoggerOSLog` to record what would otherwise
    /// reach `os.Logger`. The public surface stays at
    /// ``init(subsystem:minimumLevel:)``.
    ///
    /// - Parameters:
    ///   - subsystem: The OSLog subsystem identifier. Stored on the
    ///     returned logger and made available via ``subsystem`` for
    ///     introspection. The custom `emit` closure decides whether
    ///     to actually forward it to a real `os.Logger`.
    ///   - minimumLevel: The minimum severity to emit. Defaults to
    ///     ``MinimumLevel/defaultLevel``.
    ///   - emit: Receives every entry that passes the drop guard. The
    ///     closure must be `@Sendable`; the entry is already rendered
    ///     to a privacy-safe `String` before it reaches the closure.
    init(
        subsystem: String,
        minimumLevel: MinimumLevel = .defaultLevel,
        emit: @escaping @Sendable (LoggerDomain, OSLogType, String) -> Void
    ) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
        self.emit = emit
    }

    public func log(
        _ level: LoggerLevel,
        _ domain: LoggerDomain,
        _ message: @autoclosure @escaping @Sendable () -> LogMessage,
        attributes: @autoclosure @escaping @Sendable () -> [LogAttribute]
    ) {
        guard level != .disabled,
              level >= minimumLevel.asLoggerLevel
        else { return }
        let messageText = message().redactedDescription
        let resolved = attributes()
        let line: String = if resolved.isEmpty {
            messageText
        } else {
            messageText + " {" + resolved
                .map(\.redactedDescription)
                .joined(separator: ", ") + "}"
        }
        emit(domain, level.asOSLogType, line)
    }
}

extension OSLogLogger.MinimumLevel {
    fileprivate var asLoggerLevel: LoggerLevel {
        switch self {
        case .trace: return .trace
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .warning: return .warning
        case .error: return .error
        case .critical: return .critical
        }
    }
}

extension LoggerLevel {
    /// The `OSLogType` that this `LoggerLevel` maps onto for the
    /// universal OSLog adapter. `LoggerLevel.disabled` is not a
    /// severity and has no native counterpart; the adapter drops
    /// `.disabled` entries before this mapping is consulted, so the
    /// sentinel maps conservatively to `.debug` and is never observed
    /// at runtime.
    fileprivate var asOSLogType: OSLogType {
        switch self {
        case .disabled: return .debug
        case .trace: return .debug
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        @unknown default: return .default
        }
    }
}

/// A thread-safe cache of `os.Logger` instances keyed by
/// `LoggerDomain`.
///
/// `os.Logger` is cheap to construct but not free; rebuilding one per
/// emit allocates and crosses a synchronized boundary inside the
/// unified logging system. The production initializer of
/// `OSLogLogger` builds one cache per logger instance and reuses
/// `os.Logger` instances per category for the lifetime of the
/// `OSLogLogger`.
private final class OSLoggerCache: @unchecked Sendable {
    private let subsystem: String
    private let lock = NSLock()
    private var loggersByDomain: [LoggerDomain: os.Logger] = [:]

    init(subsystem: String) {
        self.subsystem = subsystem
    }

    /// Returns the `os.Logger` cached for `domain`, building it on
    /// first access. Thread-safe; concurrent callers that arrive
    /// before the first build observe the same instance.
    func logger(for domain: LoggerDomain) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }
        if let cached = loggersByDomain[domain] {
            return cached
        }
        let built = os.Logger(subsystem: subsystem, category: domain.rawValue)
        loggersByDomain[domain] = built
        return built
    }
}
