import Foundation

/// The app's control socket (docs/design/09-wayforkctl.md § Control socket): one
/// newline-terminated JSON request per connection, one reply.
public enum ControlPaths {
    public static let socketName = "control.sock"
    public static let pendingName = "control-pending.json"

    /// `~/Library/Application Support/Wayfork/control.sock`.
    public static func socket(in directory: URL = StoreRepository.defaultDirectory()) -> URL {
        directory.appendingPathComponent(socketName)
    }

    public static func pending(in directory: URL = StoreRepository.defaultDirectory()) -> URL {
        directory.appendingPathComponent(pendingName)
    }
}

public enum ControlMethod: String, Codable, Sendable, CaseIterable {
    case status
    case failed
    case rulesList = "rules.list"
    case rulesAdd = "rules.add"
    case rulesRemove = "rules.remove"
    case logLevelSet = "logLevel.set"
    case confirm
    case revert
    case reconnect
}

public struct ControlParams: Codable, Sendable, Hashable {
    /// `rules.add`: the pattern as typed. `rules.remove`: a pattern or a rule id.
    public var pattern: String?
    /// `rules.add`, `rules.list`: a tunnel or group name or id, or `direct`.
    public var via: String?
    public var level: LogLevel?
    /// `reconnect`: a tunnel name or id.
    public var tunnel: String?
    /// Seconds; nil → `ControlDeadline.defaultSeconds`, 0 → commit immediately.
    public var confirmWithin: Int?
    public var dryRun: Bool?

    public init(
        pattern: String? = nil, via: String? = nil, level: LogLevel? = nil,
        tunnel: String? = nil, confirmWithin: Int? = nil, dryRun: Bool? = nil
    ) {
        self.pattern = pattern
        self.via = via
        self.level = level
        self.tunnel = tunnel
        self.confirmWithin = confirmWithin
        self.dryRun = dryRun
    }
}

public struct ControlRequest: Codable, Sendable, Hashable {
    public var id: Int
    public var method: ControlMethod
    public var params: ControlParams

    public init(id: Int = 1, method: ControlMethod, params: ControlParams = ControlParams()) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ControlError: Error, Codable, Sendable, Hashable {
    public enum Code: String, Codable, Sendable {
        case badRequest, notFound, invalid, pendingChange, noPendingChange, `internal`
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum ControlDeadline {
    public static let defaultSeconds = 60
    public static let range = 10...600

    /// Nil: commit immediately. Throws `badRequest` outside 0 and `range`.
    public static func seconds(_ requested: Int?) throws -> Int? {
        let seconds = requested ?? defaultSeconds
        if seconds == 0 { return nil }
        guard range.contains(seconds) else {
            throw ControlError(
                .badRequest,
                "confirmWithin must be 0 or \(range.lowerBound)–\(range.upperBound) seconds")
        }
        return seconds
    }
}

/// Wire encoding. Results are any JSON value, produced by the handler; the CLI prints them
/// as they are, so it never needs their Swift types.
public enum ControlWire {
    public static let maxRequestBytes = 64 * 1024

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func encodeRequest(_ request: ControlRequest) throws -> Data {
        var data = try encoder().encode(request)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> ControlRequest {
        do {
            return try JSONDecoder().decode(ControlRequest.self, from: data)
        } catch {
            throw ControlError(.badRequest, "malformed request: \(error)")
        }
    }

    /// `{"id":…,"result":…}` or `{"id":…,"error":{…}}`, newline-terminated.
    public static func encodeReply(id: Int, _ reply: Result<Data, ControlError>) -> Data {
        var data = Data("{\"id\":\(id),".utf8)
        switch reply {
        case .success(let result):
            data.append(Data("\"result\":".utf8))
            data.append(result)
        case .failure(let error):
            data.append(Data("\"error\":".utf8))
            data.append((try? encoder().encode(error)) ?? Data("{}".utf8))
        }
        data.append(Data("}\n".utf8))
        return data
    }

    /// The reply's result as a JSON value, or its error.
    public static func decodeReply(_ data: Data) throws -> Result<Any, ControlError> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlError(.internal, "malformed reply")
        }
        if let error = object["error"] {
            let errorData = try JSONSerialization.data(withJSONObject: error)
            return .failure(try JSONDecoder().decode(ControlError.self, from: errorData))
        }
        return .success(object["result"] ?? NSNull())
    }

    public static func encodeResult<T: Encodable>(_ value: T) -> Result<Data, ControlError> {
        do {
            return .success(try encoder().encode(value))
        } catch {
            return .failure(ControlError(.internal, "cannot encode reply: \(error)"))
        }
    }
}

// MARK: - Shared reply payloads

/// A rule as `rules.list` and change replies show it.
public struct ControlRuleInfo: Codable, Sendable, Hashable {
    public var id: UUID
    public var pattern: String
    public var match: RuleMatch
    /// The exit's name, or `direct`.
    public var via: String
    public var enabled: Bool
    public var note: String?

    public init(_ rule: Rule, via: String) {
        id = rule.id
        pattern = rule.pattern
        match = rule.match
        self.via = via
        enabled = rule.isEnabled
        note = rule.note
    }
}

/// The change waiting for `confirm` (docs/design/09-wayforkctl.md § Dead-man confirm);
/// also the content of `control-pending.json`.
public struct PendingControlChange: Codable, Sendable, Hashable {
    public var edit: StoreEdit
    public var description: String
    public var deadline: Date

    public init(edit: StoreEdit, description: String, deadline: Date) {
        self.edit = edit
        self.description = description
        self.deadline = deadline
    }
}

/// What `pending` looks like in replies.
public struct ControlPendingInfo: Codable, Sendable, Hashable {
    public var description: String
    public var deadline: Date
    public var secondsLeft: Int

    public init(_ pending: PendingControlChange, now: Date = Date()) {
        description = pending.description
        deadline = pending.deadline
        secondsLeft = max(0, Int(pending.deadline.timeIntervalSince(now).rounded(.up)))
    }
}

public struct ControlChangeReply: Codable, Sendable, Hashable {
    public var change: String
    public var dryRun: Bool
    public var rule: ControlRuleInfo?
    /// The apply the change triggered succeeded. False with Wayfork off, on a dry run, or
    /// when the apply failed (`applyError`).
    public var applied: Bool
    public var applyError: String?
    public var pending: ControlPendingInfo?
    /// Set on `revert` when (part of) the inverse was skipped.
    public var skipped: String?

    public init(
        change: String, dryRun: Bool = false, rule: ControlRuleInfo? = nil,
        applied: Bool = false, applyError: String? = nil, pending: ControlPendingInfo? = nil,
        skipped: String? = nil
    ) {
        self.change = change
        self.dryRun = dryRun
        self.rule = rule
        self.applied = applied
        self.applyError = applyError
        self.pending = pending
        self.skipped = skipped
    }
}
