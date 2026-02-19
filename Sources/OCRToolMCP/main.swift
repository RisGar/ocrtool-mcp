// OCRToolMCP.swift
// A Swift-based MCP-compliant module for Vision OCR on macOS

import Foundation
import Vision
import AppKit

struct OCRRequest: Codable {
    let image_path: String
    let lang: String?
    let enhanced: Bool?
    let format: String? // Renamed property
    let comment: Bool? // New property
    let language: String? // New property
    let url: String? // New property
    let base64: String? // New property
}

struct BoundingBox: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct OCRLine: Codable {
    let text: String
    let bbox: BoundingBox
}

struct OCRResponse: Codable {
    let lines: [OCRLine]
    
    // New property for output formatting customization
    var formattedOutput: String {
        return lines.map { $0.text }.joined(separator: "\n")
    }

    var markdownTable: String {
        guard !lines.isEmpty else { return "No text found." }
        let header = "| Text | X | Y | Width | Height |"
        let separator = "|------|---|---|--------|--------|"
        let rows = lines.map { line in
            let b = line.bbox
            return "| \(line.text.replacingOccurrences(of: "|", with: "\\|")) | \(Int(b.x)) | \(Int(b.y)) | \(Int(b.width)) | \(Int(b.height)) |"
        }
        return ([header, separator] + rows).joined(separator: "\n")
    }

    func asCommented(language: String) -> String {
        let prefix: String
        switch language.lowercased() {
        case "python", "shell", "bash":
            prefix = "# "
        case "cpp", "c++", "java", "swift", "go":
            prefix = "// "
        case "html", "xml":
            return "<!--\n" + formattedOutput + "\n-->"
        default:
            prefix = "// "
        }
        return formattedOutput.split(separator: "\n").map { prefix + $0 }.joined(separator: "\n")
    }
}

func handleOCR(_ request: OCRRequest) -> OCRResponse {
    if let urlString = request.url, let url = URL(string: urlString) {
        do {
            let data = try Data(contentsOf: url)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to: tempURL)
            fputs("🔽 Downloaded image from URL to: \(tempURL.path)\n", stderr)
            return handleOCR(OCRRequest(
                image_path: tempURL.path,
                lang: request.lang,
                enhanced: request.enhanced,
                format: request.format,
                comment: request.comment,
                language: request.language,
                url: nil,
                base64: nil
            ))
        } catch {
            fputs("❌ Failed to download or save image from URL: \(error.localizedDescription)\n", stderr)
            return OCRResponse(lines: [])
        }
    }

    if let base64String = request.base64, !base64String.isEmpty {
        if let data = Data(base64Encoded: base64String) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            do {
                try data.write(to: tempURL)
                fputs("🧬 Decoded base64 image to: \(tempURL.path)\n", stderr)
                return handleOCR(OCRRequest(
                    image_path: tempURL.path,
                    lang: request.lang,
                    enhanced: request.enhanced,
                    format: request.format,
                    comment: request.comment,
                    language: request.language,
                    url: nil,
                    base64: nil
                ))
            } catch {
                fputs("❌ Failed to write decoded base64 image: \(error.localizedDescription)\n", stderr)
                return OCRResponse(lines: [])
            }
        } else {
            fputs("❌ Invalid base64 image data.\n", stderr)
            return OCRResponse(lines: [])
        }
    }

    fputs("🖼️ Loading image at: \(request.image_path)\n", stderr)
    
    guard FileManager.default.fileExists(atPath: request.image_path) else {
        fputs("Error: Image file not found at path: \(request.image_path)\n", stderr)
        return OCRResponse(lines: [])
    }

    guard let nsImage = NSImage(contentsOfFile: request.image_path),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fputs("Error: Unsupported or unreadable image format at path: \(request.image_path)\n", stderr)
        return OCRResponse(lines: [])
    }

    let size = CGSize(width: cgImage.width, height: cgImage.height)
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    var results: [OCRLine] = []

    let req = VNRecognizeTextRequest { req, err in
        guard err == nil else { return }
        guard let observations = req.results as? [VNRecognizedTextObservation] else { return }

        let blocks = observations.compactMap { obs -> OCRLine? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let rect = VNImageRectForNormalizedRect(obs.boundingBox, Int(size.width), Int(size.height))
            return OCRLine(text: candidate.string, bbox: BoundingBox(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
        }

        results = blocks
    }

    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = request.lang?.components(separatedBy: "+") ?? ["zh-Hans", "en-US"]

    do {
        try handler.perform([req])
    } catch {
        fputs("Vision error: \(error.localizedDescription)\n", stderr)
    }
    
    return OCRResponse(lines: results)
}

// JSON-RPC structure
struct JSONRPCRequestFlexible: Codable {
    let jsonrpc: String
    let id: CodableValue
    let method: String
    let params: [String: CodableValue]
}

enum CodableValue: Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case object([String: CodableValue]) // New case

    var string: String? {
        if case .string(let str) = self { return str }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var int: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var jsonStringEscaped: String {
        switch self {
        case .string(let str): return "\"\(str)\""
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .object(_): return "\"[object]\"" // Updated to handle .object
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let obj = try? container.decode([String: CodableValue].self) { // Support for nested objects
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str): try container.encode(str)
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .object(let dict): try container.encode(dict) // Support for encoding .object
        }
    }
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: CodableValue
    let result: OCRResponse
}

func readLineData() -> Data? {
    guard let line = readLine(strippingNewline: true) else { return nil }
    return line.data(using: .utf8)
}

func showHelpAndExit() {
    let helpText = """
    OCRToolMCP Help - Parameters Overview:
    
    image / image_path : Path to the local image file (string)
    url                : URL to download image (string)
    base64             : Base64 encoded image (string)
    lang               : OCR language(s), e.g., "en+zh" (string)
    enhanced           : Use enhanced recognition (true/false)
    format             : Output format (text, simple, table, markdown, auto, full, structured)
    output.insertAsComment : If true, insert output as code comments
    output.language    : Language style for comment output, e.g., python, swift, html
    
    JSON-RPC Method: "ocr_text"
    
    Example usage:
    {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "ocr_text",
      "params": {
        "image": "sample.jpg",
        "lang": "en+zh",
        "format": "markdown"
      }
    }
    """
    print(helpText)
    exit(0)
}

if CommandLine.arguments.contains("--help") {
    showHelpAndExit()
}

while let inputData = readLineData() {
    guard let inputStr = String(data: inputData, encoding: .utf8),
          inputStr.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" else { continue }
    let decoder = JSONDecoder()
    do {
        let flexible = try decoder.decode(JSONRPCRequestFlexible.self, from: inputData)
        switch flexible.method {
        case "ocr_text":
            let imagePath = flexible.params["image"]?.string ?? flexible.params["image_path"]?.string ?? ""
            let hasImagePath = !imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUrl = flexible.params["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasBase64 = flexible.params["base64"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            
            if [hasImagePath, hasUrl, hasBase64].filter({ $0 }).count != 1 {
                fputs("""
                {
                  "jsonrpc": "2.0",
                  "id": \(flexible.id.jsonStringEscaped),
                  "error": {
                    "code": -32602,
                    "message": "Exactly one of 'image'/'image_path', 'url', or 'base64' must be provided."
                  }
                }
                \n
                """, stdout)
                fflush(stdout)
                continue
            }

            if hasImagePath && hasUrl {
                fputs("""
                {
                  "jsonrpc": "2.0",
                  "id": \(flexible.id.jsonStringEscaped),
                  "error": {
                    "code": -32602,
                    "message": "Conflicting parameters: use only one of 'image'/'image_path' or 'url'."
                  }
                }
                \n
                """, stdout)
                fflush(stdout)
                continue
            }
            
            
            if let formatValue = flexible.params["format"]?.string,
               !["text", "simple", "table", "markdown", "auto", "full", "structured"].contains(formatValue.lowercased()) {
                fputs("""
                {
                  "jsonrpc": "2.0",
                  "id": \(flexible.id.jsonStringEscaped),
                  "error": {
                    "code": -32602,
                    "message": "Invalid value for 'format': '\(formatValue)'",
                    "hint": "Allowed values are: text, simple, table, markdown, auto, full, structured"
                  }
                }
                \n
                """, stdout)
                fflush(stdout)
                continue
            }

            var fullPath = imagePath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
            if !fullPath.hasPrefix("/") {
                fullPath = FileManager.default.currentDirectoryPath + "/" + fullPath
            }

            let req = OCRRequest(
                image_path: fullPath,
                lang: flexible.params["lang"]?.string ?? "zh+en",
                enhanced: flexible.params["enhanced"]?.bool ?? true,
                format: flexible.params["format"]?.string,
                comment: flexible.params["output.insertAsComment"]?.bool,
                language: flexible.params["output.language"]?.string,
                url: flexible.params["url"]?.string,
                base64: flexible.params["base64"]?.string
            )
            let result = handleOCR(req)
            
            // Updated conditional output check
            if req.comment == true {
                let lang = req.language ?? "python"
                print(result.asCommented(language: lang))
            } else {
                switch req.format?.lowercased() {
                case "text", "simple":
                    print(result.formattedOutput)
                case "table", "markdown":
                    print(result.markdownTable)
                case "auto":
                    if result.lines.count == 1 {
                        print(result.formattedOutput)
                    } else {
                        print(result.markdownTable)
                    }
                case "full", "structured", .none:
                    let response = JSONRPCResponse(jsonrpc: "2.0", id: flexible.id, result: result)
                    let encoded = try JSONEncoder().encode(response)
                    let prettyPrintedData = try JSONSerialization.jsonObject(with: encoded)
                    let formattedJSON = try JSONSerialization.data(withJSONObject: prettyPrintedData, options: [.prettyPrinted])
                    if let formattedStr = String(data: formattedJSON, encoding: .utf8) {
                        fputs(formattedStr + "\n", stdout)
                        fflush(stdout)
                    }
                default:
                    fputs("Unknown format option: \(req.format ?? "nil")\n", stderr)
                    print(result.formattedOutput)
                }
            }
        case "initialize":
            let response = """
            {
              "jsonrpc": "2.0",
              "id": \(flexible.id.jsonStringEscaped),
              "result": {
                "protocolVersion": "2024-11-05",
                "metadata": {
                  "name": "ocrtool-mcp",
                  "description": "Local macOS OCR tool using Vision Framework",
                  "version": "0.1.0"
                }
              }
            }
            \n
            """
            fputs(response, stdout)
            fflush(stdout)

        case "shutdown":
            let response = """
            {
              "jsonrpc": "2.0",
              "id": \(flexible.id.jsonStringEscaped),
              "result": null
            }
            \n
            """
            fputs(response, stdout)
            fflush(stdout)
            exit(0)

        case "notifications/cancelled":
            fputs("⚠️ Request cancelled (reason: timeout or interruption)\n", stderr)

        default:
            fputs("""
            {
              "jsonrpc": "2.0",
              "id": \(flexible.id.jsonStringEscaped),
              "error": {
                "code": -32601,
                "message": "Method not found"
              }
            }
            \n
            """, stdout)
            fflush(stdout)
        }
    } catch {
        fputs("Decode error: \(error.localizedDescription)\n", stderr)
        fputs("""
        {
          "jsonrpc": "2.0",
          "id": null,
          "error": {
            "code": -32602,
            "message": "Invalid request: Ensure JSON is complete and contains fields like 'method' and 'params'.",
            "details": "\(error.localizedDescription)"
          }
        }
        \n
        """, stdout)
        fflush(stdout)
    }
}
