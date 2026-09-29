import Foundation
import PrimSimCore

/// App CLI for Prim connectors. Human stdout by default; `--json` for machines.
public enum DesktopCLI {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static let usage = """
    prims-desktop — configure and operate Prims Desktop connectors

      prims-desktop connectors
      prims-desktop status [<name>]
      prims-desktop receive imessage-chatdb-receive [--limit N]
      prims-desktop open
      prims-desktop doctor
      prims-desktop asmp
      prims-desktop config get [<name>]
      prims-desktop config set <name> <field> <value>
      prims-desktop add request <pack.prim> [<relative-target>]
      prims-desktop add list
      prims-desktop add approve <request-id>
      prims-desktop add deny <request-id>

    --json anywhere. Overlay is ~/.prim/registry.local.json (not a second store).
    ASMP health is http://127.0.0.1:7749/health.
    """

    public static let fdaNote = ProductIdentity.fdaNote

    public static func run(_ args: [String]) -> Int32 {
        let result = invoke(args)
        if !result.stdout.isEmpty {
            fputs(result.stdout, stdout)
            if !result.stdout.hasSuffix("\n") { fputs("\n", stdout) }
        }
        if !result.stderr.isEmpty {
            fputs(result.stderr, stderr)
            if !result.stderr.hasSuffix("\n") { fputs("\n", stderr) }
        }
        return result.status
    }

    public static func invoke(_ args: [String]) -> Result {
        do {
            let parsed = try parse(args)
            if parsed.help || parsed.command.isEmpty || parsed.command == "help" {
                return Result(status: 0, stdout: usage + "\n", stderr: "")
            }
            switch parsed.command {
            case "connectors":
                return try cmdConnectors(json: parsed.json)
            case "status":
                return try cmdStatus(name: parsed.positionals.first, json: parsed.json)
            case "receive":
                return try cmdReceive(name: parsed.positionals.first, limit: parsed.limit, json: parsed.json)
            case "open":
                return try cmdOpen(json: parsed.json)
            case "doctor":
                return try cmdDoctor(json: parsed.json)
            case "asmp":
                return try cmdAsmp(parsed.positionals, json: parsed.json)
            case "config":
                return try cmdConfig(parsed.positionals, json: parsed.json)
            case "add":
                return try cmdAdd(parsed.positionals, json: parsed.json)
            default:
                return fail(1, "unknown command \(parsed.command)", json: parsed.json)
            }
        } catch {
            return fail(1, error.localizedDescription, json: args.contains("--json"))
        }
    }

    // MARK: - commands

    private static func cmdConnectors(json: Bool) throws -> Result {
        let catalog = try HostCatalog.load()
        let rows = HostUI.connectors(catalog.registry.tools).map(row(for:))
        if json {
            return okJSON(["connectors": rows.map(\.json)])
        }
        if rows.isEmpty {
            return Result(status: 0, stdout: "no connectors\n", stderr: "")
        }
        let lines = rows.map(\.human)
        return Result(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func cmdStatus(name: String?, json: Bool) throws -> Result {
        let catalog = try HostCatalog.load()
        let tools: [PrimTool]
        if let name {
            guard let tool = catalog.registry.tool(named: name) else {
                return fail(1, "no connector named \(name)", json: json)
            }
            tools = [tool]
        } else {
            tools = HostUI.connectors(catalog.registry.tools)
        }
        let reports = tools.map { status(for: $0) }
        let allOk = reports.allSatisfy(\.ok)
        if json {
            let payload: [String: Any] = name == nil
                ? ["status": reports.map(\.json)]
                : reports[0].json
            return emitJSON(payload, status: allOk ? 0 : 2)
        }
        let text = reports.map(\.human).joined(separator: "\n") + "\n"
        return Result(status: allOk ? 0 : 2, stdout: text, stderr: "")
    }

    private static func cmdReceive(name: String?, limit: Int, json: Bool) throws -> Result {
        guard let name else {
            return fail(1, "receive needs a connector name", json: json)
        }
        let catalog = try HostCatalog.load()
        guard let tool = catalog.registry.tool(named: name) else {
            return fail(1, "no connector named \(name)", json: json)
        }
        guard tool.name == "imessage-chatdb-receive" else {
            return fail(1, "\(name) is not in-host; only imessage-chatdb-receive is operated here", json: json)
        }
        let received = ChatDB.receive(limit: limit)
        let note = received.ok ? received.note : fdaNote
        let messages: [[String: Any]] = received.messages.map { $0.receiveJSON(textLimit: 240) }
        var payload: [String: Any] = [
            "ok": received.ok,
            "name": name,
            "source": ChatDB.path,
            "limit": max(1, limit),
            "count": messages.count,
            "note": note,
            "messages": messages,
        ]
        if !received.ok {
            payload["error"] = fdaNote
        }
        if json {
            return emitJSON(payload, status: received.ok ? 0 : 2)
        }
        if !received.ok {
            return Result(status: 2, stdout: fdaNote + "\n", stderr: "")
        }
        if messages.isEmpty {
            return Result(status: 0, stdout: note + "\n", stderr: "")
        }
        var lines: [String] = [note]
        for msg in received.messages {
            let who: String
            if msg.fromMe {
                who = "me"
            } else if !msg.identifier.isEmpty {
                who = msg.identifier
            } else {
                who = "them"
            }
            let text = ChatDB.Message.clip(msg.text, 240)
            lines.append("  [\(msg.rowid)] \(who)  \(text)")
        }
        return Result(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func cmdOpen(json: Bool) throws -> Result {
        let app = appURL()
        guard FileManager.default.fileExists(atPath: app.path) else {
            return fail(1, "app not found at \(app.path)", json: json)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Prims Desktop"]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            return fail(1, "open -a \"Prims Desktop\" exited \(proc.terminationStatus)", json: json)
        }
        if json {
            return okJSON(["ok": true, "app": app.path])
        }
        return Result(status: 0, stdout: "opened \(app.path)\n", stderr: "")
    }

    private static func cmdDoctor(json: Bool) throws -> Result {
        let overlay = LocalOverlay.url()
        let overlayExists = FileManager.default.fileExists(atPath: overlay.path)
        let overlayTools = (try? LocalOverlay.load())?.tools.map(\.name) ?? []
        let app = appURL()
        let appExists = FileManager.default.fileExists(atPath: app.path)
        let appTeam = appExists ? teamIdentifier(for: app) : nil
        let trampoline = ProductIdentity.trampolineURL()
        let trampolineExists = FileManager.default.isExecutableFile(atPath: trampoline.path)
        let trampolineIsScript = trampolineExists && !isMachO(trampoline)
        let helper = helperURL()
        let helperExists = FileManager.default.isExecutableFile(atPath: helper.path)
        let helperTeam = helperExists ? teamIdentifier(for: helper) : nil
        let chatdbHelper = ProductIdentity.chatdbHelperURL()
        let chatdbHelperExists = FileManager.default.isExecutableFile(atPath: chatdbHelper.path)
        let readable = ChatDB.health()
        let connectors = (try? HostCatalog.load()).map { HostUI.connectors($0.registry.tools) } ?? []
        let asmp = ASMP.doctor(connectors: connectors)
        let payload: [String: Any] = [
            "overlay": overlay.path,
            "overlay_exists": overlayExists,
            "overlay_tools": overlayTools,
            "app": app.path,
            "app_exists": appExists,
            "bundle_identifier": ProductIdentity.bundleIdentifier,
            "codesign_team": appTeam ?? "",
            "cli": trampoline.path,
            "cli_exists": trampolineExists,
            "cli_is_trampoline": trampolineIsScript,
            "cli_team": "",
            "helper": helper.path,
            "helper_exists": helperExists,
            "helper_team": helperTeam ?? "",
            "chatdb_helper": chatdbHelper.path,
            "chatdb_helper_exists": chatdbHelperExists,
            "chat_db": ChatDB.path,
            "chat_db_readable": readable,
            "fda": readable,
            "fda_note": fdaNote,
            "asmp": ASMP.json(asmp),
        ]
        if json {
            return emitJSON(payload, status: 0)
        }
        let lines = [
            "overlay     \(overlay.path)\(overlayExists ? "" : "  (missing)")",
            "overlay tools  \(overlayTools.isEmpty ? "(none)" : overlayTools.joined(separator: ", "))",
            "app         \(app.path)\(appExists ? "" : "  (missing)")",
            "identifier  \(ProductIdentity.bundleIdentifier)",
            "codesign    \(appTeam ?? "(unsigned / unknown)")",
            "trampoline  \(trampoline.path)\(trampolineExists ? (trampolineIsScript ? "  (script)" : "  (NOT a trampoline)") : "  (not installed)")",
            "helper      \(helper.path)\(helperExists ? "" : "  (missing)")",
            "helper team \(helperTeam ?? "(unsigned / unknown)")",
            "chatdb helper  \(chatdbHelper.path)\(chatdbHelperExists ? "" : "  (missing)")",
            "chat.db     \(readable ? "readable" : "locked (FDA)")",
            "asmp        \(asmp.registered ? "registered" : "missing")  health=\(asmp.health ? "ok" : "down")  caps_match=\(asmp.capsMatch ? "yes" : "no")",
            "asmp health \(ASMP.healthURL.absoluteString)",
            "asmp connectors  \(asmp.announcedConnectors.isEmpty ? "(none announced)" : asmp.announcedConnectors.joined(separator: ", "))",
        ]
        return Result(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private static func cmdAdd(_ positionals: [String], json: Bool) throws -> Result {
        let action = positionals.first ?? "list"
        switch action {
        case "list":
            let rows = try PendingAdd.list().map {
                ["id": $0.id.uuidString, "source": $0.sourcePath, "sha256": $0.sourceSHA256,
                 "profile": $0.profile, "target": $0.relativeTarget, "status": $0.status]
            }
            if json { return okJSON(["requests": rows]) }
            if rows.isEmpty { return Result(status: 0, stdout: "no add requests\n", stderr: "") }
            let text = rows.map { "\($0["id"]!)  \($0["status"]!)  \($0["profile"]!):\($0["target"]!)" }.joined(separator: "\n")
            return Result(status: 0, stdout: text + "\n", stderr: "")
        case "request":
            guard positionals.count >= 2 else { return fail(1, "add request needs <pack.prim>", json: json) }
            let source = URL(fileURLWithPath: positionals[1]).standardizedFileURL
            let target = positionals.count >= 3 ? positionals[2] : nil
            let req = try PendingAdd.request(source: source, relativeTarget: target)
            if json { return okJSON(["id": req.id.uuidString, "source": req.sourcePath, "sha256": req.sourceSHA256, "profile": req.profile, "target": req.relativeTarget, "status": req.status]) }
            return Result(status: 0, stdout: "requested \(req.id.uuidString) → \(req.profile):\(req.relativeTarget)\n", stderr: "")
        case "approve", "deny":
            guard positionals.count == 2, let id = UUID(uuidString: positionals[1]) else {
                return fail(1, "add \(action) needs a request UUID", json: json)
            }
            if action == "deny" {
                try PendingAdd.deny(id: id)
                return json ? okJSON(["id": id.uuidString, "status": "denied"]) : Result(status: 0, stdout: "denied \(id.uuidString)\n", stderr: "")
            }
            let target = try PendingAdd.approve(id: id)
            return json ? okJSON(["id": id.uuidString, "status": "approved", "path": target.path]) : Result(status: 0, stdout: "approved \(id.uuidString) → \(target.path)\n", stderr: "")
        default:
            return fail(1, "add action must be request, list, approve, or deny", json: json)
        }
    }

    private static func cmdConfig(_ positionals: [String], json: Bool) throws -> Result {
        let action = positionals.first ?? "get"
        switch action {
        case "get":
            let local = try LocalOverlay.load()
            if let name = positionals.dropFirst().first {
                guard let tool = local.tool(named: name) else {
                    return fail(1, "\(name) is not in the overlay", json: json)
                }
                if json { return okJSON(row(for: tool).json) }
                return Result(status: 0, stdout: row(for: tool).human + "\n", stderr: "")
            }
            if json {
                return okJSON([
                    "path": LocalOverlay.url().path,
                    "tools": local.tools.map { row(for: $0).json },
                ])
            }
            var lines = ["overlay  \(LocalOverlay.url().path)"]
            if local.tools.isEmpty {
                lines.append("(empty)")
            } else {
                lines.append(contentsOf: local.tools.map { row(for: $0).human })
            }
            return Result(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
        case "set":
            let rest = Array(positionals.dropFirst())
            guard rest.count >= 3 else {
                return fail(1, "config set needs <name> <field> <value>", json: json)
            }
            let catalog = try HostCatalog.load()
            let tool = try LocalOverlay.setField(tool: rest[0], field: rest[1], value: rest[2], catalog: catalog.registry)
            let preserved = (try LocalOverlay.load()).tools.map(\.name)
            if json {
                return okJSON([
                    "ok": true,
                    "tool": row(for: tool).json,
                    "overlay_tools": preserved,
                ])
            }
            return Result(
                status: 0,
                stdout: "set \(tool.name).\(rest[1])=\(rest[2])\noverlay tools  \(preserved.joined(separator: ", "))\n",
                stderr: ""
            )
        default:
            return fail(1, "config expects get or set", json: json)
        }
    }

    private static func cmdAsmp(_ positionals: [String], json: Bool) throws -> Result {
        if positionals.first == "serve" {
            // Forever. Does not return on success.
            return Result(status: ASMP.serveHealth(), stdout: "", stderr: "")
        }
        let catalog = try HostCatalog.load()
        let connectors = HostUI.connectors(catalog.registry.tools)
        let report = try ASMP.announceLive(connectors: connectors)
        if json {
            return okJSON([
                "ok": true,
                "announced": report.announced,
                "capabilities": report.capabilities,
                "health": report.health,
                "health_url": report.healthURL,
                "yaml": report.yaml,
                "registry": report.registry,
            ])
        }
        let lines = [
            "yaml       \(report.yaml)",
            "health     \(report.health ? "ok" : "down")  \(report.healthURL)",
            "announced  \(report.announced.joined(separator: ", "))",
            "caps       \(report.capabilities.joined(separator: ", "))",
        ]
        return Result(status: report.health ? 0 : 2, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: - rows / status

    private struct ConnectorRow {
        var json: [String: Any]
        var human: String
    }

    private static func row(for tool: PrimTool) -> ConnectorRow {
        let inHost = HostUI.isInHost(tool)
        let json: [String: Any] = [
            "name": tool.name,
            "kind": tool.kind,
            "direction": tool.direction,
            "as": tool.as ?? "",
            "cites": tool.cites,
            "bin": tool.bin ?? "",
            "in_host": inHost,
        ]
        let human = [
            tool.name,
            tool.kind,
            tool.direction,
            "as=\(tool.as ?? "-")",
            "cites=\(tool.cites)",
            "bin=\(tool.bin ?? "-")",
            "in-host=\(inHost ? "yes" : "no")",
        ].joined(separator: "  ")
        return ConnectorRow(json: json, human: human)
    }

    private struct StatusReport {
        var ok: Bool
        var json: [String: Any]
        var human: String
    }

    private static func status(for tool: PrimTool) -> StatusReport {
        if HostUI.isInHost(tool) {
            let readable = ChatDB.health()
            let note = readable ? "chat.db readable" : "chat.db locked (FDA)"
            let json: [String: Any] = [
                "name": tool.name,
                "ok": readable,
                "in_host": true,
                "chat_db": ChatDB.path,
                "chat_db_readable": readable,
                "fda": readable,
                "note": readable ? note : fdaNote,
            ]
            return StatusReport(
                ok: readable,
                json: json,
                human: "\(tool.name)  \(note)"
            )
        }
        let bin = resolveBin(tool)
        let exists = bin.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let json: [String: Any] = [
            "name": tool.name,
            "ok": exists || tool.bin == nil,
            "in_host": false,
            "bin": bin?.path ?? (tool.bin ?? ""),
            "bin_exists": exists,
        ]
        let note: String
        if let bin {
            note = exists ? "bin \(bin.path)" : "bin missing \(bin.path)"
        } else {
            note = "as=\(tool.as ?? tool.kind) (no bin)"
        }
        return StatusReport(
            ok: exists || tool.bin == nil,
            json: json,
            human: "\(tool.name)  \(note)"
        )
    }

    private static func resolveBin(_ tool: PrimTool) -> URL? {
        let names = [tool.bin, tool.name].compactMap { $0 }
        let roots = [
            ProductIdentity.helpersDirectory(),
            Paths.home().appendingPathComponent(".local/bin"),
        ]
        for root in roots {
            for name in names {
                let url = root.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        if let name = names.first {
            return ProductIdentity.helpersDirectory().appendingPathComponent(name)
        }
        return nil
    }

    // MARK: - parse / emit

    private struct Parsed {
        var json: Bool
        var help: Bool
        var limit: Int
        var command: String
        var positionals: [String]
    }

    private static func parse(_ args: [String]) throws -> Parsed {
        var json = false
        var help = false
        var limit = 8
        var command = ""
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--json" {
                json = true
                i += 1
                continue
            }
            if arg == "--help" || arg == "-h" {
                help = true
                i += 1
                continue
            }
            if arg == "--limit" {
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else {
                    throw LocalOverlay.OverlayError("--limit needs a positive integer")
                }
                limit = n
                i += 1
                continue
            }
            if arg.hasPrefix("--") {
                throw LocalOverlay.OverlayError("unknown flag \(arg)")
            }
            if command.isEmpty {
                command = arg
            } else {
                positionals.append(arg)
            }
            i += 1
        }
        return Parsed(json: json, help: help, limit: limit, command: command, positionals: positionals)
    }

    private static func fail(_ code: Int32, _ message: String, json: Bool) -> Result {
        if json {
            return emitJSON(["ok": false, "error": message], status: code)
        }
        return Result(status: code, stdout: "", stderr: "prims-desktop: \(message)\n")
    }

    private static func okJSON(_ obj: [String: Any]) -> Result {
        emitJSON(obj, status: 0)
    }

    private static func emitJSON(_ obj: [String: Any], status: Int32) -> Result {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
              let text = String(data: data, encoding: .utf8)
        else {
            return Result(status: 1, stdout: "", stderr: "prims-desktop: JSON serialization failed\n")
        }
        return Result(status: status, stdout: text + "\n", stderr: "")
    }

    public static func appURL() -> URL {
        ProductIdentity.appURL()
    }

    public static func helperURL() -> URL {
        ProductIdentity.cliHelperURL()
    }

    public static func cliURL() -> URL {
        let helper = helperURL()
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
        let trampoline = ProductIdentity.trampolineURL()
        if FileManager.default.isExecutableFile(atPath: trampoline.path) {
            return trampoline
        }
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") {
            return URL(fileURLWithPath: argv0)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(argv0)
    }

    public static func isMachO(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let magic = fh.readData(ofLength: 4)
        guard magic.count == 4 else { return false }
        let word = magic.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch word {
        case 0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca:
            return true
        default:
            return false
        }
    }

    public static func teamIdentifier(for url: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=4", url.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                return value == "not set" ? nil : value
            }
        }
        return nil
    }
}
