import Foundation
import LoggerOSLog
import Loggers
import os
import Testing

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }
}

private final class EntryRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let domain: LoggerDomain
        let level: OSLogType
        let line: String
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(entry)
    }
}

private func makeLogger(
    subsystem: String = "com.example.test",
    minimumLevel: OSLogLogger.MinimumLevel = .trace,
    sink: EntryRecorder
) -> OSLogLogger {
    OSLogLogger(
        subsystem: subsystem,
        minimumLevel: minimumLevel
    ) { domain, level, line in
        sink.append(EntryRecorder.Entry(domain: domain, level: level, line: line))
    }
}

private func recordEvaluationAndReturn<T>(
    _ counter: CallCounter,
    _ value: T
) -> T {
    counter.tick()
    return value
}

@Suite("OSLogLogger")
struct OSLogLoggerTests {
    // MARK: Drop guard

    @Test("Disabled level drops without evaluating message or attributes")
    func disabledIsDroppedWithoutEvaluation() {
        let recorder = EntryRecorder()
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.log(
            .disabled,
            "D",
            recordEvaluationAndReturn(messageCounter, "msg"),
            attributes: recordEvaluationAndReturn(
                attributesCounter,
                [LogAttribute("k", "v")]
            )
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
        #expect(recorder.entries.isEmpty)
    }

    @Test("Below-threshold level drops without evaluating message or attributes")
    func belowThresholdIsDroppedWithoutEvaluation() {
        let recorder = EntryRecorder()
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = makeLogger(minimumLevel: .error, sink: recorder)

        logger.log(
            .info,
            "D",
            recordEvaluationAndReturn(messageCounter, "msg"),
            attributes: recordEvaluationAndReturn(
                attributesCounter,
                [LogAttribute("k", "v")]
            )
        )

        #expect(messageCounter.value == 0)
        #expect(attributesCounter.value == 0)
        #expect(recorder.entries.isEmpty)
    }

    @Test("Message and attributes are evaluated exactly once on emit")
    func payloadEvaluatedExactlyOnce() {
        let recorder = EntryRecorder()
        let messageCounter = CallCounter()
        let attributesCounter = CallCounter()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.log(
            .info,
            "D",
            recordEvaluationAndReturn(messageCounter, "ok"),
            attributes: recordEvaluationAndReturn(
                attributesCounter,
                [LogAttribute("k", "v")]
            )
        )

        #expect(messageCounter.value == 1)
        #expect(attributesCounter.value == 1)
        #expect(recorder.entries.count == 1)
    }

    @Test("Default minimum level is warning")
    func defaultMinimumLevelIsWarning() {
        let recorder = EntryRecorder()
        let logger = OSLogLogger(
            subsystem: "com.example.test"
        ) { domain, level, line in
            recorder.append(EntryRecorder.Entry(domain: domain, level: level, line: line))
        }
        for level: LoggerLevel in [.trace, .debug, .info, .notice, .warning, .error, .critical] {
            logger.log(level, "D", "msg")
        }
        let levels = recorder.entries.map(\.level)
        #expect(levels == [.default, .error, .fault])
    }

    // MARK: Mapping

    @Test(
        "LoggerLevel maps onto OSLogType per the seven-severity model",
        arguments: [
            (LoggerLevel.trace, OSLogType.debug),
            (.debug, .debug),
            (.info, .info),
            (.notice, .default),
            (.warning, .default),
            (.error, .error),
            (.critical, .fault)
        ]
    )
    func levelMapping(level: LoggerLevel, expected: OSLogType) throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.log(level, "D", "msg")

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].level == expected)
    }

    @Test("LoggerDomain becomes the OSLog category passed to the sink")
    func domainBecomesCategory() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.log(.info, "Network", "msg")

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].domain == "Network")
    }

    // MARK: Privacy and attribute rendering

    @Test("Private message segment is rendered as <private> in the line")
    func privateSegmentRedacted() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)
        let username = "alice"

        logger.info("Auth", "User \(username, privacy: .private) signed in")

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "User <private> signed in")
    }

    @Test("Sensitive message segment is rendered as <redacted> in the line")
    func sensitiveSegmentRedacted() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)
        let token = "ey..."

        logger.info("Auth", "Token \(token, privacy: .sensitive)")

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "Token <redacted>")
    }

    @Test("Attributes are appended in caller order as a brace-delimited tail")
    func attributesAppendedAfterMessage() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        // Intentionally not alphabetical: locks in caller-order
        // semantics. `attributes` is an array, so the rendering must
        // preserve the order the call site provided rather than
        // sorting by key.
        logger.info(
            "Net",
            "ok",
            attributes: [
                LogAttribute("status", 200),
                LogAttribute("path", "/v1/users")
            ]
        )

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "ok {status=200, path=/v1/users}")
    }

    @Test("Empty attributes do not produce a trailing brace block")
    func emptyAttributesProduceNoTail() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.info("Net", "ok")

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "ok")
    }

    @Test("Private attribute value is redacted in the appended tail")
    func privateAttributeRedacted() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.info(
            "Auth",
            "ok",
            attributes: [LogAttribute("user", "alice", privacy: .private)]
        )

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "ok {user=<private>}")
    }

    @Test("Sensitive attribute value is redacted in the appended tail")
    func sensitiveAttributeRedacted() throws {
        let recorder = EntryRecorder()
        let logger = makeLogger(minimumLevel: .trace, sink: recorder)

        logger.info(
            "Auth",
            "ok",
            attributes: [LogAttribute("token", "secret", privacy: .sensitive)]
        )

        try #require(recorder.entries.count == 1)
        #expect(recorder.entries[0].line == "ok {token=<redacted>}")
    }

    // MARK: Public surface

    @Test("MinimumLevel allCases is in declaration order")
    func minimumLevelAllCasesOrder() {
        #expect(OSLogLogger.MinimumLevel.allCases == [
            .trace, .debug, .info, .notice, .warning, .error, .critical
        ])
    }

    @Test("subsystem and minimumLevel are exposed for introspection")
    func subsystemAndMinimumLevelAreExposed() {
        let recorder = EntryRecorder()
        let logger = makeLogger(
            subsystem: "com.example.svc",
            minimumLevel: .info,
            sink: recorder
        )
        #expect(logger.subsystem == "com.example.svc")
        #expect(logger.minimumLevel == .info)
    }
}
