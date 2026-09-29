import CryptoKit
import Foundation

public enum PendingAdd {
    public struct Request: Codable, Identifiable, Sendable {
        public var id: UUID
        public var sourcePath: String
        public var sourceSHA256: String
        public var profile: String
        public var relativeTarget: String
        public var createdAt: Date
        public var status: String
    }

    private struct Queue: Codable { var version = 1; var requests: [Request] = [] }
    private struct Desktop: Codable {
        struct Profile: Codable { var folder: String }
        var active_profile: String
        var profiles: [String: Profile]
    }

    public static func queueURL(home: URL = Paths.home()) -> URL {
        home.appendingPathComponent("prims/pending-additions.json")
    }

    public static func list(home: URL = Paths.home()) throws -> [Request] {
        try load(home: home).requests
    }

    public static func request(source: URL, relativeTarget: String? = nil, home: URL = Paths.home()) throws -> Request {
        guard source.pathExtension == "prim", FileManager.default.fileExists(atPath: source.path) else {
            throw LocalOverlay.OverlayError("source must be an existing .prim file")
        }
        let (profile, _) = try activeProfile(home: home)
        let target = try safeTarget(relativeTarget ?? "orf/" + source.lastPathComponent)
        let digest = try sha256(source)
        var queue = try load(home: home)
        if let prior = queue.requests.first(where: { $0.sourceSHA256 == digest && $0.profile == profile && $0.relativeTarget == target && $0.status == "pending" }) {
            return prior
        }
        let req = Request(id: UUID(), sourcePath: source.path, sourceSHA256: digest, profile: profile, relativeTarget: target, createdAt: Date(), status: "pending")
        queue.requests.append(req)
        try save(queue, home: home)
        return req
    }

    public static func approve(id: UUID, home: URL = Paths.home()) throws -> URL {
        var queue = try load(home: home)
        guard let i = queue.requests.firstIndex(where: { $0.id == id }) else {
            throw LocalOverlay.OverlayError("pending add request not found")
        }
        guard queue.requests[i].status == "pending" else {
            throw LocalOverlay.OverlayError("request is not pending")
        }
        let req = queue.requests[i]
        let source = URL(fileURLWithPath: req.sourcePath)
        guard try sha256(source) == req.sourceSHA256 else {
            throw LocalOverlay.OverlayError("source changed since admission was requested")
        }
        let (active, root) = try activeProfile(home: home)
        guard active == req.profile else {
            throw LocalOverlay.OverlayError("active profile changed; request belongs to \(req.profile)")
        }
        let target = root.appendingPathComponent(try safeTarget(req.relativeTarget))
        guard target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw LocalOverlay.OverlayError("target escapes active profile")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw LocalOverlay.OverlayError("target already exists")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        queue.requests[i].status = "approved"
        try save(queue, home: home)
        return target
    }

    public static func deny(id: UUID, home: URL = Paths.home()) throws {
        var queue = try load(home: home)
        guard let i = queue.requests.firstIndex(where: { $0.id == id }) else {
            throw LocalOverlay.OverlayError("pending add request not found")
        }
        guard queue.requests[i].status == "pending" else {
            throw LocalOverlay.OverlayError("request is not pending")
        }
        queue.requests[i].status = "denied"
        try save(queue, home: home)
    }

    private static func activeProfile(home: URL) throws -> (String, URL) {
        let url = home.appendingPathComponent("prims/desktop.json")
        let desktop = try JSONDecoder().decode(Desktop.self, from: Data(contentsOf: url))
        guard let profile = desktop.profiles[desktop.active_profile] else {
            throw LocalOverlay.OverlayError("active Prims profile is not configured")
        }
        return (desktop.active_profile, URL(fileURLWithPath: profile.folder, isDirectory: true))
    }

    private static func safeTarget(_ value: String) throws -> String {
        let clean = value.replacingOccurrences(of: "\\", with: "/")
        guard !clean.hasPrefix("/"), !clean.split(separator: "/").contains(".."), clean.hasSuffix(".prim") else {
            throw LocalOverlay.OverlayError("target must be a relative .prim path without '..'")
        }
        return clean
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func load(home: URL) throws -> Queue {
        let url = queueURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return Queue() }
        return try JSONDecoder().decode(Queue.self, from: Data(contentsOf: url))
    }

    private static func save(_ queue: Queue, home: URL) throws {
        let url = queueURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(queue)
        try data.write(to: url, options: .atomic)
    }
}
