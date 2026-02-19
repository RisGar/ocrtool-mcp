// OCRToolMCP - MCP Server for macOS Vision OCR
// Implements the Model Context Protocol (2025-11-25) over stdio transport
// Spec: https://modelcontextprotocol.io/specification/2025-11-25

import Foundation
import Vision
import AppKit

// MARK: - JSON-RPC 2.0 Types

/// A JSON value that can be any valid JSON type.
/// Used for flexible encoding/decoding of JSON-RPC messages.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: Bool before Int/Double because Bool decodes as Int in Swift
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Cannot decode JSONValue")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let d): try container.encode(d)
        case .integer(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    /// Extract a string value, or nil
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Extract a bool value, or nil
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Extract an object value, or nil
    var objectValue: [String: JSONValue]? {
        if case .object(let obj) = self { return obj }
        return nil
    }
}

/// JSON-RPC 2.0 Request ID — can be string or integer, never null per MCP spec.
enum JSONRPCID: Codable, Equatable {
    case string(String)
    case integer(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "ID must be string or integer")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        }
    }
}

/// Incoming JSON-RPC message — could be a request (has id) or notification (no id).
struct IncomingMessage: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String?
    let params: JSONValue?

    /// Whether this is a valid JSON-RPC 2.0 message
    var isValid: Bool { jsonrpc == "2.0" }

    /// Whether this is a notification (no id)
    var isNotification: Bool { id == nil && method != nil }

    /// Whether this is a request (has id and method)
    var isRequest: Bool { id != nil && method != nil }
}

// MARK: - JSON-RPC Error Codes

/// Standard JSON-RPC 2.0 error codes
enum JSONRPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

// MARK: - Response Writing

/// Writes a single JSON-RPC response line to stdout.
/// Per MCP stdio transport spec: messages are newline-delimited, must not contain embedded newlines.
func writeResponse(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys] // Compact, no pretty-printing — no embedded newlines
    do {
        let data = try encoder.encode(value)
        if let line = String(data: data, encoding: .utf8) {
            fputs(line + "\n", stdout)
            fflush(stdout)
        }
    } catch {
        log("Failed to encode response: \(error.localizedDescription)")
    }
}

/// Build and write a JSON-RPC result response
func writeResult(id: JSONRPCID, result: JSONValue) {
    writeResponse(.object([
        "jsonrpc": .string("2.0"),
        "id": idToJSON(id),
        "result": result
    ]))
}

/// Build and write a JSON-RPC error response
func writeError(id: JSONRPCID?, code: Int, message: String, data: JSONValue? = nil) {
    var error: [String: JSONValue] = [
        "code": .integer(code),
        "message": .string(message)
    ]
    if let d = data {
        error["data"] = d
    }

    var response: [String: JSONValue] = [
        "jsonrpc": .string("2.0"),
        "error": .object(error)
    ]
    if let id = id {
        response["id"] = idToJSON(id)
    } else {
        response["id"] = .null
    }
    writeResponse(.object(response))
}

/// Convert JSONRPCID to JSONValue
func idToJSON(_ id: JSONRPCID) -> JSONValue {
    switch id {
    case .string(let s): return .string(s)
    case .integer(let i): return .integer(i)
    }
}

/// Log to stderr (allowed by MCP spec for stdio transport)
func log(_ message: String) {
    fputs("[ocrtool-mcp] \(message)\n", stderr)
}

// MARK: - OCR Engine

struct OCRResult {
    struct Line {
        let text: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    let lines: [Line]
    let error: String?
}

/// Perform OCR on an image and return structured results.
func performOCR(imagePath: String?, imageURL: String?, imageBase64: String?, languages: String?) -> OCRResult {
    // Resolve image to a local file path
    let resolvedPath: String
    do {
        resolvedPath = try resolveImageSource(path: imagePath, url: imageURL, base64: imageBase64)
    } catch {
        return OCRResult(lines: [], error: error.localizedDescription)
    }

    log("Loading image at: \(resolvedPath)")

    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        return OCRResult(lines: [], error: "Image file not found at path: \(resolvedPath)")
    }

    guard let nsImage = NSImage(contentsOfFile: resolvedPath),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return OCRResult(lines: [], error: "Unsupported or unreadable image format at path: \(resolvedPath)")
    }

    let size = CGSize(width: cgImage.width, height: cgImage.height)
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    var ocrLines: [OCRResult.Line] = []

    let request = VNRecognizeTextRequest { request, error in
        guard error == nil else { return }
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

        ocrLines = observations.compactMap { obs -> OCRResult.Line? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let rect = VNImageRectForNormalizedRect(obs.boundingBox, Int(size.width), Int(size.height))
            return OCRResult.Line(
                text: candidate.string,
                x: Int(rect.origin.x),
                y: Int(rect.origin.y),
                width: Int(rect.width),
                height: Int(rect.height)
            )
        }
    }

    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages?.components(separatedBy: "+") ?? ["en-US"]

    do {
        try handler.perform([request])
    } catch {
        return OCRResult(lines: [], error: "Vision OCR failed: \(error.localizedDescription)")
    }

    return OCRResult(lines: ocrLines, error: nil)
}

/// Resolve an image source (path, URL, or base64) to a local file path.
func resolveImageSource(path: String?, url: String?, base64: String?) throws -> String {
    if let urlString = url, !urlString.isEmpty {
        guard let downloadURL = URL(string: urlString) else {
            throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }
        let data = try Data(contentsOf: downloadURL)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: tempURL)
        log("Downloaded image from URL to: \(tempURL.path)")
        return tempURL.path
    }

    if let base64String = base64, !base64String.isEmpty {
        guard let data = Data(base64Encoded: base64String) else {
            throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 image data"])
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: tempURL)
        log("Decoded base64 image to: \(tempURL.path)")
        return tempURL.path
    }

    if let imagePath = path, !imagePath.isEmpty {
        var fullPath = imagePath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        if !fullPath.hasPrefix("/") {
            fullPath = FileManager.default.currentDirectoryPath + "/" + fullPath
        }
        return fullPath
    }

    throw NSError(domain: "OCR", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image source provided. Supply 'image_path', 'url', or 'base64'."])
}

// MARK: - Tool Definitions

/// The OCR tool definition per MCP spec
let ocrToolDefinition: JSONValue = .object([
    "name": .string("ocr_text"),
    "title": .string("OCR Text Extraction"),
    "description": .string("Extract text from an image using macOS Vision OCR. Provide exactly one image source: a local file path, a URL, or base64-encoded data."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
            "image_path": .object([
                "type": .string("string"),
                "description": .string("Absolute or relative path to a local image file")
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("URL to download the image from")
            ]),
            "base64": .object([
                "type": .string("string"),
                "description": .string("Base64-encoded image data")
            ]),
            "lang": .object([
                "type": .string("string"),
                "description": .string("OCR languages separated by '+', e.g. 'en-US+zh-Hans'. Default: 'en-US'")
            ])
        ])
    ])
])

// MARK: - MCP Server State

/// Server lifecycle state per MCP spec
enum ServerState {
    case awaitingInit
    case running
}

var serverState: ServerState = .awaitingInit

// MARK: - Request Handlers

/// Handle the `initialize` request per MCP lifecycle spec
func handleInitialize(id: JSONRPCID, params: JSONValue?) {
    guard serverState == .awaitingInit else {
        writeError(id: id, code: JSONRPCErrorCode.invalidRequest, message: "Server already initialized")
        return
    }

    // Extract client's requested protocol version
    let clientVersion = params?.objectValue?["protocolVersion"]?.stringValue

    // We support 2025-11-25 and 2024-11-05
    let supportedVersions = ["2025-11-25", "2024-11-05"]
    let negotiatedVersion: String
    if let cv = clientVersion, supportedVersions.contains(cv) {
        negotiatedVersion = cv
    } else {
        // Respond with our latest supported version
        negotiatedVersion = supportedVersions[0]
    }

    writeResult(id: id, result: .object([
        "protocolVersion": .string(negotiatedVersion),
        "capabilities": .object([
            "tools": .object([:])
        ]),
        "serverInfo": .object([
            "name": .string("ocrtool-mcp"),
            "version": .string("1.0.0")
        ])
    ]))
}

/// Handle the `notifications/initialized` notification
func handleInitialized() {
    guard serverState == .awaitingInit else {
        log("Received initialized notification in unexpected state")
        return
    }
    serverState = .running
    log("Session initialized, entering operation phase")
}

/// Handle `ping` request
func handlePing(id: JSONRPCID) {
    writeResult(id: id, result: .object([:]))
}

/// Handle `tools/list` request
func handleToolsList(id: JSONRPCID) {
    writeResult(id: id, result: .object([
        "tools": .array([ocrToolDefinition])
    ]))
}

/// Handle `tools/call` request
func handleToolsCall(id: JSONRPCID, params: JSONValue?) {
    guard let paramsObj = params?.objectValue else {
        writeError(id: id, code: JSONRPCErrorCode.invalidParams, message: "Missing params")
        return
    }

    guard let toolName = paramsObj["name"]?.stringValue else {
        writeError(id: id, code: JSONRPCErrorCode.invalidParams, message: "Missing 'name' in params")
        return
    }

    guard toolName == "ocr_text" else {
        writeError(id: id, code: JSONRPCErrorCode.invalidParams, message: "Unknown tool: \(toolName)")
        return
    }

    let arguments = paramsObj["arguments"]?.objectValue ?? [:]

    // Extract tool arguments
    let imagePath = arguments["image_path"]?.stringValue ?? arguments["image"]?.stringValue
    let imageURL = arguments["url"]?.stringValue
    let imageBase64 = arguments["base64"]?.stringValue
    let lang = arguments["lang"]?.stringValue

    // Validate: exactly one image source must be provided
    let sourceCount = [imagePath, imageURL, imageBase64].compactMap({ $0 }).filter({ !$0.isEmpty }).count
    if sourceCount == 0 {
        writeResult(id: id, result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Error: No image source provided. Supply exactly one of 'image_path', 'url', or 'base64'.")
                ])
            ]),
            "isError": .bool(true)
        ]))
        return
    }
    if sourceCount > 1 {
        writeResult(id: id, result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Error: Multiple image sources provided. Supply exactly one of 'image_path', 'url', or 'base64'.")
                ])
            ]),
            "isError": .bool(true)
        ]))
        return
    }

    // Perform OCR
    let result = performOCR(imagePath: imagePath, imageURL: imageURL, imageBase64: imageBase64, languages: lang)

    if let error = result.error {
        writeResult(id: id, result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Error: \(error)")
                ])
            ]),
            "isError": .bool(true)
        ]))
        return
    }

    if result.lines.isEmpty {
        writeResult(id: id, result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("No text found in image.")
                ])
            ]),
            "isError": .bool(false)
        ]))
        return
    }

    // Format output as plain text (one line per recognized text block)
    let textOutput = result.lines.map { $0.text }.joined(separator: "\n")

    writeResult(id: id, result: .object([
        "content": .array([
            .object([
                "type": .string("text"),
                "text": .string(textOutput)
            ])
        ]),
        "isError": .bool(false)
    ]))
}

// MARK: - Message Dispatch

/// Route an incoming JSON-RPC message to the appropriate handler
func dispatch(_ message: IncomingMessage) {
    guard message.isValid else {
        writeError(id: message.id, code: JSONRPCErrorCode.invalidRequest, message: "Invalid JSON-RPC version (must be \"2.0\")")
        return
    }

    guard let method = message.method else {
        writeError(id: message.id, code: JSONRPCErrorCode.invalidRequest, message: "Missing method")
        return
    }

    // Handle notifications (no id — must not send a response)
    if message.isNotification {
        switch method {
        case "notifications/initialized":
            handleInitialized()
        case "notifications/cancelled":
            log("Request cancelled by client")
        case "notifications/progress":
            break // Silently accept
        case "notifications/roots/list_changed":
            break // Silently accept
        default:
            log("Ignoring unknown notification: \(method)")
        }
        return
    }

    // From here on, it's a request (has id)
    guard let id = message.id else {
        writeError(id: nil, code: JSONRPCErrorCode.invalidRequest, message: "Request missing id")
        return
    }

    // initialize and ping are allowed before initialized notification
    switch method {
    case "initialize":
        handleInitialize(id: id, params: message.params)
        return
    case "ping":
        handlePing(id: id)
        return
    default:
        break
    }

    // All other requests require the server to be in running state
    guard serverState == .running else {
        writeError(id: id, code: JSONRPCErrorCode.invalidRequest,
                   message: "Server not yet initialized. Send 'initialize' request first.")
        return
    }

    switch method {
    case "tools/list":
        handleToolsList(id: id)
    case "tools/call":
        handleToolsCall(id: id, params: message.params)
    default:
        writeError(id: id, code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(method)")
    }
}

// MARK: - Main Loop (stdio transport)

// Per MCP stdio transport spec:
// - Messages are newline-delimited JSON-RPC
// - Messages MUST NOT contain embedded newlines
// - Server reads from stdin, writes to stdout
// - Server MAY write to stderr for logging

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    let help = """
    ocrtool-mcp - MCP Server for macOS Vision OCR

    This server implements the Model Context Protocol (2025-11-25) over stdio.
    It exposes an 'ocr_text' tool for extracting text from images using
    Apple's Vision framework.

    Usage:
      ocrtool-mcp          Start the MCP server (reads JSON-RPC from stdin)
      ocrtool-mcp --help   Show this help message

    The server communicates via JSON-RPC 2.0 over stdin/stdout.
    Configure it in your MCP client (e.g., Claude Desktop) as a stdio server.

    Tool: ocr_text
      Arguments:
        image_path  - Local file path to an image
        url         - URL to download an image from
        base64      - Base64-encoded image data
        lang        - OCR languages (e.g. "en-US+zh-Hans")
    """
    fputs(help + "\n", stderr)
    exit(0)
}

log("Server starting, awaiting initialization...")

let decoder = JSONDecoder()

while let line = readLine(strippingNewline: true) {
    // Skip empty lines
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }

    // Parse the JSON-RPC message
    guard let data = trimmed.data(using: .utf8) else {
        log("Failed to convert input to UTF-8 data")
        continue
    }

    do {
        let message = try decoder.decode(IncomingMessage.self, from: data)
        dispatch(message)
    } catch {
        log("JSON parse error: \(error.localizedDescription)")
        writeError(id: nil, code: JSONRPCErrorCode.parseError,
                   message: "Parse error: \(error.localizedDescription)")
    }
}

// stdin closed — per MCP spec, this is the shutdown signal for stdio transport
log("stdin closed, shutting down")
