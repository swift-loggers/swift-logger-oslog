# swift-logger-oslog

OSLog adapter for [`swift-loggers`](https://github.com/swift-loggers)
that bridges the universal `Logger` contract to Apple's unified
logging system, preserving lazy evaluation, privacy-safe rendering,
and the seven-severity model.

Built on top of [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger);
forwards entries through
[`os.Logger`](https://developer.apple.com/documentation/os/logger).

Requires Swift 6.0+. iOS 14, macOS 11, tvOS 14, watchOS 7, visionOS 1.
MIT licensed. Pre-release; the first tagged version will be `0.1.0`.

## Installation

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger-oslog.git", branch: "main")
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

## Usage

```swift
import LoggerOSLog
import Loggers

extension LoggerDomain {
    static let auth: LoggerDomain = "Auth"
}

let logger: any Loggers.Logger = OSLogLogger(
    subsystem: "com.example.app",
    minimumLevel: .info
)

logger.info(.auth, "User signed in")
```

`LoggerDomain` becomes the OSLog `category`, the level maps onto
`OSLogType`, and the message and attributes are rendered as a single
privacy-safe text line before reaching `os.Logger`.

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

| Privacy       | Rendering             |
|---------------|-----------------------|
| `.public`     | segment value verbatim |
| `.private`    | `<private>`           |
| `.sensitive`  | `<redacted>`          |

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

## Companion packages

- [`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
  -- protocol-only core plus `PrintLogger`, `DomainFilteredLogger`,
  `NoOpLogger`. The `Logger` protocol, `LogMessage`, `LogAttribute`,
  `LoggerLevel`, and `LoggerDomain` are all defined there.
