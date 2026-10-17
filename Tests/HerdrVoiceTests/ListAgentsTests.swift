import Foundation
import Testing
@testable import HerdrVoiceCore

private let localAgents = #"{"result":{"agents":[{"name":"reviewer","pane_id":"w1:p1","agent":"pi","agent_status":"working","cwd":"/local","terminal_title_stripped":"Local review","tokens":12345}]}}"#
private let remoteAgents = #"{"result":{"agents":[{"name":"reviewer","pane_id":"w1:p1","agent":"codex","agent_status":"idle","cwd":"/remote","terminal_title_stripped":"Remote review","tokens":999},{"pane_id":"w2:p3","agent":"claude","agent_status":"blocked"}]}}"#
private let emptyAgents = #"{"result":{"agents":[]}}"#

private func agentListRows(_ output: String) throws -> [[String: String]] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: String]])
}

@Test func listAgentsCombinesLocalAndRemoteWithoutConfusingMatchingTargets() throws {
    var calls: [[String]] = []
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        calls.append(args)
        switch args {
        case ["agent", "list"]: return localAgents
        case ["machine", "list", "--json"]:
            return #"[{"id":"worker-a","label":"Build host","enabled":true}]"#
        case ["--machine", "worker-a", "agent", "list"]: return remoteAgents
        default: Issue.record("Unexpected command: \(args)"); return ""
        }
    })
    let rows = try agentListRows(outcome.output)
    #expect(outcome.watch == nil && outcome.paneWatch == nil)
    #expect(calls == [["agent", "list"], ["machine", "list", "--json"],
                      ["--machine", "worker-a", "agent", "list"]])
    #expect(rows.count == 3)
    #expect(rows[0] == ["target": "reviewer", "kind": "pi", "status": "working", "cwd": "/local", "title": "Local review"])
    #expect(rows[1] == ["target": "reviewer", "kind": "codex", "status": "idle", "cwd": "/remote", "title": "Remote review",
                       "worker": "Build host", "worker_id": "worker-a"])
    #expect(rows[2] == ["target": "w2:p3", "kind": "claude", "status": "blocked", "cwd": "", "title": "",
                       "worker": "Build host", "worker_id": "worker-a"])
}

@Test(arguments: ["[]", #"[{"id":"off","enabled":false}]"#, "error: unknown command machine",
                  #"{"error":{"message":"discovery failed"}}"#, "not JSON"])
func listAgentsPreservesLocalOutputWithoutDiscoveredWorkers(discovery: String) {
    var calls: [[String]] = []
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        calls.append(args)
        return args == ["agent", "list"] ? localAgents : discovery
    })
    #expect(outcome.output == HerdrTools.trimAgents(localAgents))
    #expect(calls == [["agent", "list"], ["machine", "list", "--json"]])
}

@Test(arguments: ["", "connection refused", #"{"error":{"code":"timeout","message":"SSH timed out"}}"#,
                  #"{"result":{"agents":"invalid"}}"#, #"{"result":{}}"#])
func listAgentsContinuesPastAnUnavailableWorker(failure: String) throws {
    var calls: [[String]] = []
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        calls.append(args)
        switch args {
        case ["agent", "list"]: return localAgents
        case ["machine", "list", "--json"]:
            return #"[{"id":"down","label":"Offline","enabled":true},{"id":"up","label":"Online","enabled":true}]"#
        case ["--machine", "down", "agent", "list"]: return failure
        case ["--machine", "up", "agent", "list"]: return remoteAgents
        default: Issue.record("Unexpected command: \(args)"); return ""
        }
    })
    let rows = try agentListRows(outcome.output)
    #expect(rows.count == 4)
    #expect(rows[0]["target"] == "reviewer" && rows[0]["worker"] == nil)
    #expect(rows[1]["worker"] == "Offline" && rows[1]["worker_id"] == "down")
    #expect(rows[1]["error"] != nil && rows[1]["target"] == nil)
    #expect(rows[2]["worker_id"] == "up" && rows[3]["worker_id"] == "up")
    #expect(calls.last == ["--machine", "up", "agent", "list"])
}

@Test func listAgentsSkipsDisabledMalformedAndDuplicateWorkers() throws {
    var calls: [[String]] = []
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        calls.append(args)
        if args == ["agent", "list"] { return emptyAgents }
        if args == ["machine", "list", "--json"] {
            return #"[{"id":"disabled","enabled":false},{"enabled":true},{"id":"","enabled":true},{"id":" ","enabled":true},{"id":3,"enabled":true},{"id":"missing-enabled"},{"id":"a","label":"Same name","enabled":true},{"id":"a","enabled":true},{"id":"b","label":"Same name","enabled":true},{"id":"c","enabled":true}]"#
        }
        return remoteAgents
    })
    #expect(calls.dropFirst(2) == [["--machine", "a", "agent", "list"], ["--machine", "b", "agent", "list"],
                                  ["--machine", "c", "agent", "list"]])
    let rows = try agentListRows(outcome.output)
    #expect(rows.count == 6)
    #expect(rows[0]["worker_id"] == "a" && rows[2]["worker_id"] == "b")
    #expect(rows[4]["worker"] == "c") // missing label falls back to the stable ID
}

@Test func listAgentsHandlesEmptyWorkersWithoutInventingAgentsOrErrors() {
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        if args == ["machine", "list", "--json"] { return #"[{"id":"empty","enabled":true}]"# }
        return emptyAgents
    })
    #expect(outcome.output == "[]")
}

@Test func listAgentsReturnsRemoteAgentsEvenWhenLocalListingFails() throws {
    let failure = #"{"error":{"message":"local server unavailable"}}"#
    let outcome = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        switch args {
        case ["agent", "list"]: return failure
        case ["machine", "list", "--json"]: return #"[{"id":"up","enabled":true}]"#
        default: return remoteAgents
        }
    })
    let rows = try agentListRows(outcome.output)
    #expect(rows.count == 3 && rows[0]["error"] == "Local agent listing unavailable")
    #expect(rows[1]["worker_id"] == "up")
    let localOnly = HerdrTools.call("list_agents", arguments: "{}", run: { args in
        args == ["agent", "list"] ? failure : "[]"
    })
    #expect(localOnly.output == failure)
}

@Test func listAgentsSchemaExplainsWorkerScopeAndUnavailableRows() throws {
    let schema = try #require(HerdrTools.schemas(includeShell: false).first { $0["name"] as? String == "list_agents" })
    let description = try #require(schema["description"] as? String)
    #expect(description.contains("worker_id") && description.contains("unavailable") && description.contains("discovery-only"))
}
