import Foundation

struct ChatGPTTranscriptionService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!

    func transcribe(
        audioURL: URL,
        credential: ChatGPTAuthManager.Credential,
        language: String = "zh"
    ) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = "VoiceKey-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("Codex Desktop/26.707.8479.0 (Windows; x64)", forHTTPHeaderField: "User-Agent")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        body.appendMultipart(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: "audio/wav",
            data: audioData,
            boundary: boundary
        )
        body.appendMultipart(
            name: "language",
            value: language,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw TranscriptionError.authenticationExpired
            case 429:
                throw TranscriptionError.rateLimited
            default:
                throw TranscriptionError.http(http.statusCode, detail)
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.noText
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriptionError: LocalizedError {
        case invalidResponse
        case authenticationExpired
        case rateLimited
        case http(Int, String)
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Invalid transcription response."
            case .authenticationExpired: "ChatGPT authorization expired. Open VoiceKey and sign in again."
            case .rateLimited: "ChatGPT transcription is temporarily rate limited."
            case .http(let status, let detail):
                detail.isEmpty ? "Transcription failed (HTTP \(status))." : "Transcription failed (HTTP \(status)): \(detail)"
            case .noText: "No speech was recognized."
            }
        }
    }
}

private extension Data {
    mutating func appendMultipart(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }
}
