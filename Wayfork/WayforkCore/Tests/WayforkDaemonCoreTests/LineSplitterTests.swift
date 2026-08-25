import Testing

@testable import WayforkDaemonCore

@Test func lineSplitterHandlesLFAndCRLF() {
    var splitter = LineSplitter()
    #expect(splitter.append(Array("one\ntwo\r\nthree\n".utf8)) == ["one", "two", "three"])
    #expect(splitter.flush() == nil)
}

@Test func lineSplitterHandlesTerminatorsSplitAcrossAppends() {
    var splitter = LineSplitter()
    #expect(splitter.append(Array("one\r".utf8)).isEmpty)
    #expect(splitter.append(Array("\ntwo".utf8)) == ["one"])
    #expect(splitter.append(Array("\n".utf8)) == ["two"])
}

@Test func lineSplitterKeepsLoneCarriageReturn() {
    var splitter = LineSplitter()
    #expect(splitter.append(Array("one\rtwo\n".utf8)) == ["one\rtwo"])
}

@Test func lineSplitterReplacesInvalidUTF8() {
    var splitter = LineSplitter()
    #expect(splitter.append([0x66, 0x80, 0x6F, 0x0A]) == ["f�o"])
}

@Test func lineSplitterFlushesPartialLineOnce() {
    var splitter = LineSplitter()
    #expect(splitter.append(Array("partial".utf8)).isEmpty)
    #expect(splitter.flush() == "partial")
    #expect(splitter.flush() == nil)
}
