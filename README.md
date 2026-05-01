# swift-logger-oslog

OSLog adapter for [`swift-loggers`](https://github.com/swift-loggers)
that bridges the universal `Logger` contract to Apple's unified
logging system, preserving lazy evaluation, privacy-safe rendering,
and the seven-severity model.

Built on top of [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger);
forwards entries through
[`os.Logger`](https://developer.apple.com/documentation/os/logger).

Requires Swift 6.0+. iOS 14, macOS 11, tvOS 14, watchOS 7, visionOS 1.
MIT licensed.

API reference:
[swift-loggers.github.io/swift-logger-oslog](https://swift-loggers.github.io/swift-logger-oslog/documentation/loggeroslog/).

## Installation

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger-oslog.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerOSLog", package: "swift-logger-oslog")
            ]
        )
    ]
)
```

The example uses SwiftPM's `from:` requirement, so consumers
follow tagged releases starting at `0.1.0` (up to but not
including the next major version). Applications that require a
fully pinned dependency can use `exact: "0.1.0"` instead.

## Usage

A service holds a `Logger`. At startup an `OSLogLogger` is created
and passed in; the same protocol carries plain strings, privacy-aware
interpolation, and structured attributes, and the OSLog adapter
forwards every shape to `os.Logger` after redacting privacy-annotated
content.

Use a reverse-DNS `subsystem` for the app or library that owns the
logs. `minimumLevel` is the emission threshold; entries below it are
dropped before their message or attributes are evaluated.

```swift
import LoggerOSLog
import Loggers

extension LoggerDomain {
    static let auth: LoggerDomain = "Auth"
}

struct AuthService {
    let logger: any Loggers.Logger

    func signOut() {
        logger.info(.auth, "User signed out")
    }

    func validate(username: String) {
        logger.debug(
            .auth,
            "Validating input for \(username, privacy: .private)"
        )
    }

    func signIn(username: String, password _: String) {
        let success = true
        logger.info(
            .auth,
            "Sign-in \(success ? "succeeded" : "failed")",
            attributes: [
                LogAttribute("auth.method", "password"),
                LogAttribute("auth.success", success),
                LogAttribute("auth.username", username, privacy: .private)
            ]
        )
        // Password is bound to `_` so the service never even names it
        // when logging; an HTTP client downstream owns the network
        // call and any HTTP-level logging.
    }
}

let logger: any Loggers.Logger = OSLogLogger(
    subsystem: "com.example.app",
    minimumLevel: .debug
)

let authService = AuthService(logger: logger)

func runAuthLoggingExample() {
    authService.signOut()
    authService.validate(username: "alice")
    authService.signIn(username: "alice", password: "not-logged")
}
```

## Mapping

| `LoggerLevel` | `OSLogType` |
|---------------|-------------|
| `trace`       | `debug`     |
| `debug`       | `debug`     |
| `info`        | `info`      |
| `notice`      | `default`   |
| `warning`     | `default`   |
| `error`       | `error`     |
| `critical`    | `fault`     |

The seven-severity model is collapsed onto OSLog's five-level set.
`trace`/`debug` share `.debug` and `notice`/`warning` share
`.default`. The emitted line contains only the redacted message text
plus optional rendered attributes; it does not include a separate
`LoggerLevel` prefix. The original `LoggerLevel` reaches `os.Logger`
through `OSLogType` only.

## Privacy

`OSLogLogger` is a safe-text adapter. It runs every entry through
`LogMessage.redactedDescription` and `LogAttribute.redactedDescription`
before reaching `os.Logger`:

| Privacy       | Rendering              |
|---------------|------------------------|
| `.public`     | segment value verbatim |
| `.private`    | `<private>`            |
| `.sensitive`  | `<redacted>`           |

The redacted text is then passed to `os.Logger` with a compile-time
`\(text, privacy: .public)` interpolation, which is safe because the
runtime payload has already been redacted. This means OSLog's native
privacy system is not used; privacy is fully enforced at the adapter
level via redaction.

`OSLogLogger` does **not** reconstruct an `OSLogMessage` with
per-segment privacy from runtime `LogSegment` arrays: `OSLogMessage`
is a compile-time construct and cannot be assembled reliably from
dynamic data. True OSLog interpolation privacy (`%{public}s` /
`%{private}s` / `%{sensitive}s`) is available only by using Apple's
`os.Logger` directly with a literal interpolation; that path is
intentionally outside the universal `Logger` contract.

## Related packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- the core ecosystem package. It provides the core logging
  abstractions in the `Loggers` product, along with the built-in
  companion adapters (`LoggerPrint`, `LoggerFiltering`,
  `LoggerNoOp`) and the `LoggerLibrary` umbrella product that
  re-exports them for consumer-facing use.
