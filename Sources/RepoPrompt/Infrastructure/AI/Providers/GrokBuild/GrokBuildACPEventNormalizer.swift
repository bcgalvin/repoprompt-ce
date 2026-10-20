import Foundation

/// Grok Build session-update normalizer. Native search_replace/write calls are
/// classified as edit before shared transcript merging. Terminal tool updates reuse
/// the shared canonical durable-result adapter; all other updates delegate to the
/// default ACP normalizer.
enum GrokBuildACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        guard let sessionUpdate = (payload["sessionUpdate"] as? String)?.lowercased() else {
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }

        switch sessionUpdate {
        case "tool_call", "tool_call_update":
            var normalizedPayload = payload
            if sessionUpdate == "tool_call" {
                let nativeName = ACPRuntimeEventParsing.normalizedToolName(from: payload)
                if nativeName == "search_replace" || nativeName == "write" {
                    normalizedPayload["toolName"] = "edit"
                }
            }
            return ACPDefaultSessionUpdateNormalizer.normalize(
                ACPToolUpdateResultAdapter.adaptedTerminalToolUpdatePayload(normalizedPayload, sessionUpdate: sessionUpdate),
                providerID: .grokBuild
            )
        default:
            return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: .grokBuild)
        }
    }
}
