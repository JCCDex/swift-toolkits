import Foundation
@testable import SwiftDappConnect
import Testing

@Test func `success payload keeps nonce and serializes result types`() {
    let nullPayload = NativeResponseChannel.successPayload(nonce: "n1", result: .null)
    #expect(nullPayload["nonce"] as? String == "n1")
    #expect(nullPayload["result"] is NSNull)

    let stringPayload = NativeResponseChannel.successPayload(nonce: "n2", result: .string("0x123"))
    #expect(stringPayload["result"] as? String == "0x123")

    let numberPayload = NativeResponseChannel.successPayload(nonce: "n3", result: .number(NSNumber(value: 123)))
    #expect(numberPayload["result"] as? NSNumber == NSNumber(value: 123))

    let objectPayload = NativeResponseChannel.successPayload(nonce: "n4", result: .object(["a": 1]))
    #expect((objectPayload["result"] as? [String: Any])?["a"] as? Int == 1)

    let arrayPayload = NativeResponseChannel.successPayload(nonce: "n5", result: .array(["0x1", "0x2"]))
    #expect((arrayPayload["result"] as? [Any])?.count == 2)
}

@Test func `error payload carries code and message`() {
    let payload = NativeResponseChannel.errorPayload(nonce: "n1", code: 4001, message: "User rejected")
    #expect(payload["nonce"] as? String == "n1")
    let error = payload["error"] as? [String: Any]
    #expect(error?["code"] as? Int == 4001)
    #expect(error?["message"] as? String == "User rejected")
}
