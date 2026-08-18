@testable import CodexAppServerProtocol
import Foundation
import Testing

@Test func roundTripsIntegerAndStringRequestIDs() throws {
    for id in [JSONRPCID.integer(7), .string("request-7")] {
        let request = JSONRPCRequest(id: id, method: "thread/list", params: .object([:]))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        #expect(decoded.id == id)
    }
}

@Test func preservesUnknownJSONRecursively() throws {
    let data = Data(#"{"id":7,"result":{"future":{"enabled":true},"items":[1,"x",null]}}"#.utf8)
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    #expect(response.id == .integer(7))
    #expect(response.result["future"]?["enabled"] == .bool(true))
    #expect(response.result["items"] == .array([.number(1), .string("x"), .null]))
    let encoded = try JSONEncoder().encode(response)
    let roundTripped = try JSONDecoder().decode(JSONRPCResponse.self, from: encoded)
    #expect(roundTripped == response)
    #expect(roundTripped.result["future"]?["enabled"] == .bool(true))
    #expect(roundTripped.result["items"] == .array([.number(1), .string("x"), .null]))
}

@Test func buildsStableMethodsWithExactNames() {
    #expect(AppServerMethod.initialize(clientName: "bridge", title: "Bridge", version: "0.1").name == "initialize")
    #expect(AppServerMethod.initialized.name == "initialized")
    #expect(AppServerMethod.threadList.name == "thread/list")
    #expect(AppServerMethod.threadRead(threadID: "thr_1", includeTurns: true).name == "thread/read")
    #expect(AppServerMethod.threadStart(cwd: "/tmp/inbox", ephemeral: false).name == "thread/start")
    #expect(AppServerMethod.threadResume(threadID: "thr_1").name == "thread/resume")
    #expect(AppServerMethod.threadSetName(threadID: "thr_1", name: "Codex Watch").name == "thread/name/set")
    #expect(AppServerMethod.turnStart(threadID: "thr_1", clientMessageID: "memo_1", text: "note").name == "turn/start")
    #expect(AppServerMethod.threadInjectItems(threadID: "thr_1", items: []).name == "thread/inject_items")
    #expect(AppServerMethod.turnSteer(threadID: "thr_1", expectedTurnID: "turn_1", clientMessageID: "memo_1", text: "note").name == "turn/steer")
}

@Test func threadListEncodesFiltersAndOpaqueCursorWithoutInventingDefaults() {
    let defaultRequest = AppServerMethod.threadListPage(cursor: nil, sourceKinds: nil)
    #expect(defaultRequest.params == .object([:]))

    let nextRequest = AppServerMethod.threadListPage(
        cursor: "opaque-page-2",
        sourceKinds: ["cli", "vscode"]
    )
    #expect(nextRequest.params == .object([
        "cursor": .string("opaque-page-2"),
        "sourceKinds": .array([.string("cli"), .string("vscode")]),
    ]))
}

@Test func buildsStableMethodsWithExactParams() {
    #expect(AppServerMethod.initialize(clientName: "bridge", title: "Bridge", version: "0.1").params == .object([
        "clientInfo": .object([
            "name": .string("bridge"),
            "title": .string("Bridge"),
            "version": .string("0.1"),
        ]),
    ]))
    #expect(AppServerMethod.initialized.params == .object([:]))
    #expect(AppServerMethod.threadList.params == .object([:]))
    #expect(AppServerMethod.threadRead(threadID: "thr_1", includeTurns: true).params == .object([
        "threadId": .string("thr_1"),
        "includeTurns": .bool(true),
    ]))
    #expect(AppServerMethod.threadStart(cwd: "/tmp/inbox", ephemeral: false).params == .object([
        "cwd": .string("/tmp/inbox"),
        "ephemeral": .bool(false),
    ]))
    #expect(AppServerMethod.threadResume(threadID: "thr_1").params == .object([
        "threadId": .string("thr_1"),
    ]))
    #expect(AppServerMethod.threadSetName(threadID: "thr_1", name: "Codex Watch").params == .object([
        "threadId": .string("thr_1"),
        "name": .string("Codex Watch"),
    ]))
    #expect(AppServerMethod.turnStart(threadID: "thr_1", clientMessageID: "memo_1", text: "note").params == .object([
        "threadId": .string("thr_1"),
        "input": .array([.object([
            "type": .string("text"),
            "text": .string("note"),
        ])]),
        "clientUserMessageId": .string("memo_1"),
    ]))
    #expect(AppServerMethod.captureOnlyTurnStart(
        threadID: "thr_1",
        clientMessageID: "memo_1",
        text: "note"
    ).params == .object([
        "threadId": .string("thr_1"),
        "input": .array([.object([
            "type": .string("text"),
            "text": .string("note"),
        ])]),
        "clientUserMessageId": .string("memo_1"),
        "sandboxPolicy": .object([
            "type": .string("readOnly"),
            "networkAccess": .bool(false),
        ]),
        "approvalPolicy": .string("never"),
    ]))
    #expect(AppServerMethod.turnSteer(threadID: "thr_1", expectedTurnID: "turn_1", clientMessageID: "memo_1", text: "note").params == .object([
        "threadId": .string("thr_1"),
        "expectedTurnId": .string("turn_1"),
        "input": .array([.object([
            "type": .string("text"),
            "text": .string("note"),
        ])]),
        "clientUserMessageId": .string("memo_1"),
    ]))

    let rawItem: JSONValue = .object([
        "type": .string("message"),
        "role": .string("user"),
        "content": .array([.object([
            "type": .string("input_text"),
            "text": .string("raw"),
        ])]),
    ])
    #expect(AppServerMethod.responsesAPIUserMessage(text: "raw") == rawItem)
    #expect(AppServerMethod.threadInjectItems(threadID: "thr_1", items: [rawItem]).params == .object([
        "threadId": .string("thr_1"),
        "items": .array([rawItem]),
    ]))
}

@Test func selectsExactlyOneEnvelopeKind() throws {
    let decoder = JSONDecoder()
    let request = try decoder.decode(JSONRPCMessage.self, from: Data(#"{"id":"req_1","method":"thread/read","params":{"threadId":"thr_1"}}"#.utf8))
    let notification = try decoder.decode(JSONRPCMessage.self, from: Data(#"{"method":"initialized","params":{}}"#.utf8))
    let response = try decoder.decode(JSONRPCMessage.self, from: Data(#"{"id":1,"result":{}}"#.utf8))
    let error = try decoder.decode(JSONRPCMessage.self, from: Data(#"{"id":1,"error":{"code":-32600,"message":"bad request","data":{"future":true}}}"#.utf8))

    #expect(request.methodName == "thread/read")
    #expect(notification.methodName == "initialized")
    #expect(response.methodName == nil)
    #expect(error.methodName == nil)
}

@Test func rejectsEnvelopeWithoutMethodOrResult() {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(#"{"id":1}"#.utf8))
    }
}

@Test(arguments: [
    #"{"id":1,"method":"thread/list","result":{}}"#,
    #"{"id":1,"result":{},"error":{"code":-32600,"message":"bad"}}"#,
])
func rejectsAmbiguousEnvelopes(_ envelope: String) {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(envelope.utf8))
    }
}

@Test func threadProjectionPreservesFutureFields() throws {
    let data = Data(#"{"id":"thr_1","status":"futureStatus","sourceKind":"futureSource","future":{"nested":[1,true]}}"#.utf8)
    let projection = try JSONDecoder().decode(ThreadProjection.self, from: data)

    #expect(projection.status == .unknown("futureStatus"))
    #expect(projection.sourceKind == .unknown("futureSource"))

    let encoded = try JSONEncoder().encode(projection)
    let roundTripped = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(roundTripped["status"] == .string("futureStatus"))
    #expect(roundTripped["future"]?["nested"] == .array([.number(1), .bool(true)]))
}

@Test func threadProjectionDecodesAndPreservesV2ObjectStatus() throws {
    let status: JSONValue = .object([
        "type": .string("active"),
        "activeFlags": .array([.string("waitingOnApproval")]),
        "future": .object(["nested": .bool(true)]),
    ])
    let data = try JSONEncoder().encode(JSONValue.object([
        "id": .string("thr_v2"),
        "status": status,
    ]))

    let projection = try JSONDecoder().decode(ThreadProjection.self, from: data)
    #expect(projection.status == .active)

    let encoded = try JSONEncoder().encode(projection)
    let roundTripped = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(roundTripped["status"] == status)
}

@Test func threadProjectionPreservesUnknownV2ObjectStatus() throws {
    let status: JSONValue = .object([
        "type": .string("futureStatus"),
        "future": .array([.number(1), .bool(true)]),
    ])
    let data = try JSONEncoder().encode(JSONValue.object([
        "id": .string("thr_future"),
        "status": status,
    ]))

    let projection = try JSONDecoder().decode(ThreadProjection.self, from: data)
    #expect(projection.status == .unknown("futureStatus"))

    let encoded = try JSONEncoder().encode(projection)
    let roundTripped = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(roundTripped["status"] == status)
}
