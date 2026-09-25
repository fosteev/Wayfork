import Foundation

struct OpenVPNArgument {
    var value: String
    var quote: Character?
}

enum OpenVPNConfigLexer {
    static func tokenize(_ line: String, lineNumber: Int) throws -> [OpenVPNArgument] {
        var result: [OpenVPNArgument] = []
        var value = ""
        var quote: Character?
        var currentQuote: Character?
        var escaping = false
        var tokenStarted = false

        func appendToken() {
            result.append(OpenVPNArgument(value: value, quote: quote))
        }

        for character in line {
            if escaping {
                value.append(character)
                escaping = false
                tokenStarted = true
                continue
            }
            if currentQuote == "\"", character == "\\" {
                escaping = true
                tokenStarted = true
                continue
            }
            if let activeQuote = currentQuote {
                if character == activeQuote {
                    currentQuote = nil
                } else {
                    value.append(character)
                }
                tokenStarted = true
                continue
            }
            if character == "\"" || character == "'" {
                currentQuote = character
                quote = quote == nil || quote == character ? character : "\""
                tokenStarted = true
            } else if character.isWhitespace {
                if tokenStarted {
                    appendToken()
                    value = ""
                    quote = nil
                    tokenStarted = false
                }
            } else {
                value.append(character)
                tokenStarted = true
            }
        }

        if escaping || currentQuote != nil {
            throw OpenVPNImportError.malformed(line: lineNumber, reason: "unbalanced quotes")
        }
        if tokenStarted {
            appendToken()
        }
        return result
    }

    static func renderDirective(
        _ directive: String, arguments: [OpenVPNArgument]
    ) -> String {
        ([directive] + arguments.map(renderArgument)).joined(separator: " ")
    }

    static func renderArgument(_ argument: OpenVPNArgument) -> String {
        guard argument.value.contains(where: \Character.isWhitespace) else {
            return argument.value
        }
        if argument.quote == "'", !argument.value.contains("'") {
            return "'\(argument.value)'"
        }
        let escaped = argument.value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
