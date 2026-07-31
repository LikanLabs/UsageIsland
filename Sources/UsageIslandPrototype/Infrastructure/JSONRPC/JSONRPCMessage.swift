import Foundation

public enum JSONRPCRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    var diagnosticDescription: String {
        switch self {
        case .string:
            "<string>"
        case .integer(let value):
            String(value)
        }
    }

    var sanitizedForErrorStorage: JSONRPCRequestID {
        switch self {
        case .string:
            .string("<redacted>")
        case .integer:
            self
        }
    }
}

extension JSONRPCRequestID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCRequestID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        }
    }
}

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue?) {
        self.method = method
        self.params = params
    }
}

struct JSONRPCRequestMessage: Encodable {
    let id: JSONRPCRequestID
    let method: String
    let params: JSONValue?
}

struct JSONRPCNotificationMessage: Encodable {
    let method: String
    let params: JSONValue?
}

enum JSONRPCIncomingMessage: Sendable {
    case success(id: JSONRPCRequestID, result: JSONValue)
    case failure(id: JSONRPCRequestID, code: Int)
    case notification(JSONRPCNotification)
}

enum JSONRPCMessageCodec {
    static func encodeRequest(
        id: JSONRPCRequestID,
        method: String,
        params: JSONValue?
    ) throws -> Data {
        try encode(JSONRPCRequestMessage(id: id, method: method, params: params))
    }

    static func encodeNotification(method: String, params: JSONValue?) throws -> Data {
        try encode(JSONRPCNotificationMessage(method: method, params: params))
    }

    static func decodeIncoming(_ data: Data) throws -> JSONRPCIncomingMessage {
        do {
            return try JSONDecoder().decode(IncomingEnvelope.self, from: data).message
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw JSONRPCError.malformedJSON
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}

private struct IncomingEnvelope: Decodable {
    let message: JSONRPCIncomingMessage

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    private struct RemoteError: Decodable {
        let code: Int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.method) {
            guard !container.contains(.id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Server requests are not supported"
                )
            }
            let method = try container.decode(String.self, forKey: .method)
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            message = .notification(JSONRPCNotification(method: method, params: params))
            return
        }

        let id = try container.decode(JSONRPCRequestID.self, forKey: .id)
        if container.contains(.result) {
            let result = try container.decode(JSONValue.self, forKey: .result)
            message = .success(id: id, result: result)
            return
        }
        if container.contains(.error) {
            let error = try container.decode(RemoteError.self, forKey: .error)
            message = .failure(id: id, code: error.code)
            return
        }

        throw JSONRPCError.missingResponsePayload
    }
}
