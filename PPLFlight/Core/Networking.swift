import Foundation

enum HTTPError: LocalizedError {
    case status(Int, String)
    case noData
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .status(let code, let url): return "Server returned \(code) for \(url)"
        case .noData: return "No data returned"
        case .rateLimited: return "The data service is busy (rate limited). Try again in a minute."
        }
    }
}

enum HTTP {
    static let userAgent = "PPLFlight/1.0 (iOS; student pilot training app)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 300
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    static func data(_ url: URL, timeout: TimeInterval = 40, method: String = "GET", body: Data? = nil,
                     contentType: String? = nil, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 204 { return Data() }
        if http.statusCode == 429 { throw HTTPError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, url.host ?? "") }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let d = try await data(url)
        if d.isEmpty { throw HTTPError.noData }
        return try JSONDecoder().decode(T.self, from: d)
    }

    static func download(_ url: URL, to destination: URL) async throws {
        let (tmp, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url.host ?? "")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }
}

/// App directories.
enum AppPaths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PPLFlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var caches: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PPLFlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static func cacheDir(_ name: String) -> URL {
        let u = caches.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func supportDir(_ name: String) -> URL {
        let u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Codable JSON persistence in Documents (user data: plans, logbook, aircraft, settings).
enum JSONStore {
    static func url(_ name: String) -> URL { AppPaths.documents.appendingPathComponent(name + ".json") }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: url(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) {
            try? d.write(to: url(name), options: .atomic)
        }
    }
}

/// Fast RFC-4180 CSV parser over raw bytes.
enum CSV {
    static func parse(_ data: Data, row: ([String]) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var fields: [String] = []
            fields.reserveCapacity(32)
            var field: [UInt8] = []
            field.reserveCapacity(256)
            var inQuotes = false
            var i = 0
            while i < n {
                let c = p[i]
                if inQuotes {
                    if c == 34 {
                        if i + 1 < n && p[i + 1] == 34 { field.append(34); i += 1 } else { inQuotes = false }
                    } else {
                        field.append(c)
                    }
                } else {
                    switch c {
                    case 34: inQuotes = true
                    case 44:
                        fields.append(String(decoding: field, as: UTF8.self))
                        field.removeAll(keepingCapacity: true)
                    case 10:
                        fields.append(String(decoding: field, as: UTF8.self))
                        field.removeAll(keepingCapacity: true)
                        row(fields)
                        fields.removeAll(keepingCapacity: true)
                    case 13: break
                    default: field.append(c)
                    }
                }
                i += 1
            }
            if !field.isEmpty || !fields.isEmpty {
                fields.append(String(decoding: field, as: UTF8.self))
                row(fields)
            }
        }
    }
}
