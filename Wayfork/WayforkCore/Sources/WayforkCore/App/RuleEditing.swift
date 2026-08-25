import Foundation

/// Validation shared by the popover quick add and the inline rule editor
/// (docs/design/02-ux.md, `rule.invalid`).
public enum RuleEditing {
    public enum Failure: Error, Sendable, Equatable {
        case pattern(RulePatternError)
        /// Same pattern and match already exists under the same tunnel.
        case duplicate
    }

    /// Normalizes `input` for `match` and rejects duplicates within `tunnelID`'s group.
    public static func normalize(
        _ input: String, match: RuleMatch, tunnelID: UUID, store: Store, excluding ruleID: UUID?
    ) -> Result<String, Failure> {
        let pattern: String
        do {
            pattern = try RulePattern.normalize(input, match: match)
        } catch let error as RulePatternError {
            return .failure(.pattern(error))
        } catch {
            return .failure(.pattern(.invalidHostname(input)))
        }
        let duplicate = store.rules.contains {
            $0.id != ruleID && $0.tunnelID == tunnelID && $0.pattern == pattern
                && $0.match == match
        }
        return duplicate ? .failure(.duplicate) : .success(pattern)
    }

    public static func message(for failure: Failure) -> String {
        switch failure {
        case .duplicate: "This rule already exists in this group"
        case .pattern(let error): message(for: error)
        }
    }

    public static func message(for error: RulePatternError) -> String {
        switch error {
        case .empty: "Enter a domain"
        case .invalidHostname: "Not a valid domain"
        case .tooLong: "Domain is too long"
        case .wildcardNotAllowed: "`*` only allowed in wildcard rules"
        case .wildcardRequired: "Wildcard rules need a `*`"
        }
    }
}

/// "Route `<domain>` via `<tunnel>`" from the menu bar (docs/design/02-ux.md, "Quick add").
public enum QuickAdd {
    public enum Outcome: Sendable, Hashable {
        /// New rule to append.
        case add(Rule)
        /// An existing rule with the same pattern, re-pointed at the chosen tunnel.
        case update(Rule)
        case invalid(String)
    }

    /// Match type is `suffix`; a `*` in the input switches to `wildcard`.
    public static func evaluate(input: String, tunnelID: UUID, store: Store) -> Outcome {
        let match = RulePattern.inferMatch(input)
        let pattern: String
        do {
            pattern = try RulePattern.normalize(input, match: match)
        } catch let error as RulePatternError {
            return .invalid(RuleEditing.message(for: error))
        } catch {
            return .invalid(RuleEditing.message(for: .invalidHostname(input)))
        }
        if var existing = store.rules.first(where: { $0.pattern == pattern }) {
            existing.tunnelID = tunnelID
            existing.match = match
            existing.isEnabled = true
            return .update(existing)
        }
        return .add(Rule(pattern: pattern, match: match, tunnelID: tunnelID))
    }

    /// True when the input names a rule that already exists (the button reads "Update").
    public static func isUpdate(input: String, store: Store) -> Bool {
        let match = RulePattern.inferMatch(input)
        guard let pattern = try? RulePattern.normalize(input, match: match) else { return false }
        return store.rules.contains { $0.pattern == pattern }
    }

    /// The normalized host when the clipboard looks like a URL or a hostname; nil otherwise.
    public static func clipboardCandidate(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048,
            !trimmed.contains(where: \.isNewline), !trimmed.contains(" ")
        else { return nil }
        let lower = trimmed.lowercased()
        let looksLikeURL = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        guard looksLikeURL || trimmed.contains(".") else { return nil }
        guard let host = try? RulePattern.normalize(trimmed, match: .suffix), host.contains(".")
        else { return nil }
        return host
    }
}
