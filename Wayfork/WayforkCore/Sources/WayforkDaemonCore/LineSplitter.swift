public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: some Collection<UInt8>) -> [String] {
        buffer.append(contentsOf: bytes)

        var lines: [String] = []
        var lineStart = buffer.startIndex
        for index in buffer.indices where buffer[index] == 0x0A {
            var lineEnd = index
            if lineEnd > lineStart && buffer[buffer.index(before: lineEnd)] == 0x0D {
                lineEnd = buffer.index(before: lineEnd)
            }
            lines.append(String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self))
            lineStart = buffer.index(after: index)
        }

        if lineStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        return lines
    }

    public mutating func flush() -> String? {
        guard !buffer.isEmpty else {
            return nil
        }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
