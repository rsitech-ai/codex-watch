import Foundation

public struct AppServerMethod: Sendable, Equatable {
    public let name: String
    public let params: JSONValue

    private init(name: String, params: [String: JSONValue]) {
        self.name = name
        self.params = .object(params)
    }

    public static func initialize(clientName: String, title: String, version: String) -> AppServerMethod {
        AppServerMethod(name: "initialize", params: [
            "clientInfo": .object([
                "name": .string(clientName),
                "title": .string(title),
                "version": .string(version),
            ]),
        ])
    }

    public static let initialized = AppServerMethod(name: "initialized", params: [:])

    public static let threadList = AppServerMethod(name: "thread/list", params: [:])

    public static func threadListPage(
        cursor: String?,
        sourceKinds: [String]?
    ) -> AppServerMethod {
        var params: [String: JSONValue] = [:]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        if let sourceKinds {
            params["sourceKinds"] = .array(sourceKinds.map(JSONValue.string))
        }
        return AppServerMethod(name: "thread/list", params: params)
    }

    public static func threadRead(threadID: String, includeTurns: Bool) -> AppServerMethod {
        AppServerMethod(name: "thread/read", params: [
            "threadId": .string(threadID),
            "includeTurns": .bool(includeTurns),
        ])
    }

    public static func threadStart(cwd: String, ephemeral: Bool) -> AppServerMethod {
        AppServerMethod(name: "thread/start", params: [
            "cwd": .string(cwd),
            "ephemeral": .bool(ephemeral),
        ])
    }

    public static func threadResume(threadID: String) -> AppServerMethod {
        AppServerMethod(name: "thread/resume", params: ["threadId": .string(threadID)])
    }

    public static func threadSetName(threadID: String, name: String) -> AppServerMethod {
        AppServerMethod(name: "thread/name/set", params: [
            "threadId": .string(threadID),
            "name": .string(name),
        ])
    }

    public static func turnStart(
        threadID: String,
        clientMessageID: String,
        text: String
    ) -> AppServerMethod {
        AppServerMethod(name: "turn/start", params: [
            "threadId": .string(threadID),
            "input": textInput(text),
            "clientUserMessageId": .string(clientMessageID),
        ])
    }

    public static func captureOnlyTurnStart(
        threadID: String,
        clientMessageID: String,
        text: String
    ) -> AppServerMethod {
        AppServerMethod(name: "turn/start", params: [
            "threadId": .string(threadID),
            "input": textInput(text),
            "clientUserMessageId": .string(clientMessageID),
            "sandboxPolicy": .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false),
            ]),
            "approvalPolicy": .string("never"),
        ])
    }

    public static func turnSteer(
        threadID: String,
        expectedTurnID: String,
        clientMessageID: String,
        text: String
    ) -> AppServerMethod {
        AppServerMethod(name: "turn/steer", params: [
            "threadId": .string(threadID),
            "expectedTurnId": .string(expectedTurnID),
            "input": textInput(text),
            "clientUserMessageId": .string(clientMessageID),
        ])
    }

    public static func threadInjectItems(threadID: String, items: [JSONValue]) -> AppServerMethod {
        AppServerMethod(name: "thread/inject_items", params: [
            "threadId": .string(threadID),
            "items": .array(items),
        ])
    }

    public static func responsesAPIUserMessage(text: String) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string(text),
            ])]),
        ])
    }

    private static func textInput(_ text: String) -> JSONValue {
        .array([.object([
            "type": .string("text"),
            "text": .string(text),
        ])])
    }
}
