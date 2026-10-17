import Foundation

extension HerdrTools {
    /// Herdr owns saved-worker discovery, sessions, SSH authentication and transport timeouts.
    /// Never infer workers from paths or start/reconnect a remote server just to list its agents.
    static func listAgents(_ run: Runner) -> String {
        let local = run(["agent", "list"])
        let discovery = run(["machine", "list", "--json"])
        guard let workers = try? JSONSerialization.jsonObject(with: Data(discovery.utf8)) as? [[String: Any]]
        else {
            // Older Herdr versions do not have machine discovery. Keep their local behavior.
            return trimAgents(local)
        }

        var seen: Set<String> = []
        let enabled = workers.compactMap { worker -> (id: String, label: String)? in
            guard worker["enabled"] as? Bool == true,
                  let id = worker["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted
            else { return nil }
            return (id, worker["label"] as? String ?? id)
        }
        guard !enabled.isEmpty else { return trimAgents(local) }

        var agents: [[String: Any]]
        if let rows = agentRows(local) {
            agents = rows.map(slimAgent)
        } else {
            // A local socket failure must not hide healthy remote workers either.
            agents = [["error": "Local agent listing unavailable"]]
        }
        for worker in enabled {
            // IDs avoid ambiguous worker labels. Never use the inherited local session or pane IDs remotely.
            let response = run(["--machine", worker.id, "agent", "list"])
            guard let rows = agentRows(response) else {
                // Do not treat failure as an empty worker, or leak a potentially large SSH diagnostic.
                agents.append(["worker": worker.label, "worker_id": worker.id,
                               "error": "Agent listing unavailable; worker unreachable or response invalid"])
                continue
            }
            agents += rows.map { row in
                var slim = slimAgent(row)
                slim["worker"] = worker.label
                slim["worker_id"] = worker.id
                return slim
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func agentRows(_ json: String) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              obj["error"] == nil,
              let result = obj["result"] as? [String: Any]
        else { return nil }
        return result["agents"] as? [[String: Any]]
    }
}
