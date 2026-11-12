import Foundation

/// バックエンドの共通レスポンス形式 `{ message, data }`
struct APIResponse<T: Decodable>: Decodable {
    let message: String
    let data: T
}

enum APIError: LocalizedError {
    case invalidURL
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "サーバーURLが正しくありません"
        case .http(let status, let body): "エラー (\(status)): \(body)"
        }
    }
}

/// giracle-backend と通信するクライアント。
/// Cookie は URLSession.shared が自動で保存・送信する（Web の credentials: "include" 相当）。
struct APIClient {
    let baseURL: URL

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(path, method: "GET", body: nil)
    }

    /// クエリ文字列付きの GET（"user/list?username=..." の ? 以降を安全に組み立てる）
    func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        let data = try await request(path, method: "GET", body: nil, query: query)
        return try JSONDecoder.giracle().decode(APIResponse<T>.self, from: data).data
    }

    func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await send(path, method: "POST", body: try JSONEncoder().encode(body))
    }

    /// 結果の data を使わない POST
    func post(_ path: String, body: some Encodable) async throws {
        _ = try await request(path, method: "POST", body: try JSONEncoder().encode(body))
    }

    func delete<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        try await send(path, method: "DELETE", body: try JSONEncoder().encode(body))
    }

    /// 結果の data を使わない DELETE（このバックエンドは DELETE でも JSON の body を受け取る）
    func delete(_ path: String, body: some Encodable) async throws {
        _ = try await request(path, method: "DELETE", body: try JSONEncoder().encode(body))
    }

    /// ファイルをフォーム形式（multipart/form-data）で送る。
    /// Web の `const form = new FormData(); form.append("file", file)` を手で組み立てているのと同じ
    func upload<T: Decodable>(
        _ path: String,
        fields: [String: String] = [:],
        fileField: String = "file",
        file: Data,
        fileName: String,
        mimeType: String
    ) async throws -> T {
        let data = try await uploadRaw(path, fields: fields, fileField: fileField, file: file, fileName: fileName, mimeType: mimeType)
        return try JSONDecoder.giracle().decode(APIResponse<T>.self, from: data).data
    }

    /// 結果の data を使わないアップロード
    func upload(
        _ path: String,
        fields: [String: String] = [:],
        fileField: String = "file",
        file: Data,
        fileName: String,
        mimeType: String
    ) async throws {
        _ = try await uploadRaw(path, fields: fields, fileField: fileField, file: file, fileName: fileName, mimeType: mimeType)
    }

    private func uploadRaw(
        _ path: String,
        fields: [String: String],
        fileField: String,
        file: Data,
        fileName: String,
        mimeType: String
    ) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        return try await request(
            path,
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?) async throws -> T {
        let data = try await request(path, method: method, body: body)
        return try JSONDecoder.giracle().decode(APIResponse<T>.self, from: data).data
    }

    /// 通信してステータスを確認し、レスポンス本文を返す
    private func request(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String = "application/json",
        query: [URLQueryItem] = []
    ) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url = url.appending(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

extension JSONDecoder {
    /// giracle-backend の JSON 用（HTTP と WebSocket で共通）
    static func giracle() -> JSONDecoder {
        let decoder = JSONDecoder()
        // サーバーの日時は "2026-11-13T00:30:33.123Z" のようにミリ秒付きで届く
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
        }
        return decoder
    }
}
