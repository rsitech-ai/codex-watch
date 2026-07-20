@testable import CodexWatchCore
import Testing

@Test func pairingCodeAcceptsExactlySixASCIIDigits() throws {
    #expect(try PairingCode("123456").rawValue == "123456")
    #expect(throws: PairingCodeError.invalidCode) { _ = try PairingCode("12345") }
    #expect(throws: PairingCodeError.invalidCode) { _ = try PairingCode("١٢٣٤٥٦") }
    #expect(throws: PairingCodeError.invalidCode) { _ = try PairingCode("12345a") }
}

@Test func pairingInputSanitizesToTheSameASCIIContract() {
    #expect(PairingCode.sanitizeInput("12a٣34567") == "123456")
    #expect(PairingCode.sanitizeInput("١٢٣٤٥٦") == "")
}
