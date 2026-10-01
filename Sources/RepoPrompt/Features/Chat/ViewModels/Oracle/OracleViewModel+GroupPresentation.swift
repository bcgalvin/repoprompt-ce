import Foundation
import RepoPromptDomainRuntime

struct OracleMemberPresentation: Equatable {
    enum Status: String {
        case streaming = "In progress"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
        case unknown = "Status unknown"
    }

    let status: Status
    var errorMessage: String?

    static let unknown = Self(status: .unknown)
}

/// A small, transient projection of one canonical turn, not another outcome store.
struct OracleGroupPresentation: Equatable {
    struct Key: Hashable {
        let groupID: OracleGroupID
        let owner: OracleConversationOwner

        @MainActor
        init?(session: ChatSession) {
            guard let groupID = session.oracleGroupID, let tabID = session.composeTabID,
                  let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: session.workspaceID, tabID: tabID)
            else { return nil }
            self.init(groupID: OracleGroupID(rawValue: groupID), owner: owner)
        }

        init(groupID: OracleGroupID, owner: OracleConversationOwner) {
            self.groupID = groupID
            self.owner = owner
        }
    }

    let key: Key
    let revision: UInt64
    let turnID: OracleTurnID?
    let isTerminal: Bool
    let members: [OracleGroupMember]
    private(set) var lanes: [OracleLaneID: OracleMemberPresentation]
    /// The existing app runtime invocation is evidence for live events, unlike a loaded prepared record.
    var invocationID: UUID?
    private var sequences: [OracleLaneID: UInt64] = [:]

    init(document: OracleGroupDocument, invocationID: UUID? = nil) {
        key = Key(groupID: document.group.id, owner: document.owner)
        revision = document.revision
        turnID = document.turns.last?.id
        isTerminal = document.turns.last?.state == .terminal
        members = document.members
        self.invocationID = isTerminal ? nil : invocationID
        lanes = [:]
        if isTerminal, let turn = document.turns.last {
            for member in members {
                guard let result = turn.results.first(where: {
                    $0.laneIndex == member.laneID.index && $0.chatID == member.publicChatID
                }) else { continue }
                let status: OracleMemberPresentation.Status = switch result.status {
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
                lanes[member.laneID] = OracleMemberPresentation(
                    status: status,
                    errorMessage: result.error.map { "[\($0.code)] \($0.message)" }
                )
            }
        }
    }

    @MainActor
    func member(_ session: ChatSession) -> OracleMemberPresentation {
        guard Key(session: session) == key,
              let member = members.first(where: { $0.memberID.rawValue == session.id }),
              session.shortID == member.publicChatID,
              session.oracleLaneIndex == member.laneID.index,
              session.oracleGroupSize == members.count,
              session.oracleModelRaw == member.model.modelID
        else { return .unknown }
        return lanes[member.laneID] ?? .unknown
    }

    mutating func receive(_ event: OracleProgressEvent) {
        guard invocationID != nil, !isTerminal,
              event.groupID == key.groupID, event.turnID == turnID,
              event.kind == .laneStarted || event.kind == .laneSettled,
              let laneID = event.laneID, members.contains(where: { $0.laneID == laneID }),
              let sequence = event.sequence,
              sequences[laneID].map({ sequence > $0 }) ?? true
        else { return }
        sequences[laneID] = sequence
        // Settled progress precedes durable publication; it cannot establish terminal success.
        lanes[laneID] = event.kind == .laneStarted ? .init(status: .streaming) : .unknown
    }

    mutating func endExecution() {
        invocationID = nil
        if !isTerminal { lanes = [:] }
    }
}

extension OracleViewModel {
    func oracleMemberPresentation(for session: ChatSession) -> OracleMemberPresentation {
        guard let key = OracleGroupPresentation.Key(session: session),
              isCurrentOracleProjection(session)
        else { return .unknown }
        return oracleGroupPresentations[key]?.member(session) ?? .unknown
    }

    func recordOracleGroupPresentation(_ document: OracleGroupDocument, invocationID: UUID? = nil) {
        let next = OracleGroupPresentation(document: document, invocationID: invocationID)
        if let current = oracleGroupPresentations[next.key] {
            // A store read can win the race with the prepared callback for the same revision.
            let beginsKnownExecution = next.revision == current.revision && next.turnID == current.turnID
                && !current.isTerminal && current.invocationID == nil && invocationID != nil
            guard next.revision > current.revision || beginsKnownExecution else { return }
        }
        oracleGroupPresentations[next.key] = next
        pruneOracleGroupPresentations()
    }

    func receiveOracleGroupProgress(_ event: OracleProgressEvent, owner: OracleConversationOwner) {
        let key = OracleGroupPresentation.Key(groupID: event.groupID, owner: owner)
        guard var current = oracleGroupPresentations[key] else { return }
        let previous = current
        current.receive(event)
        if current != previous { oracleGroupPresentations[key] = current }
    }

    /// One group read on opening/switching groups; never per member or text delta.
    func loadOracleGroupPresentation(containing session: ChatSession) async {
        guard let key = OracleGroupPresentation.Key(session: session),
              isCurrentOracleProjection(session)
        else { return }
        let previous = oracleGroupPresentations[key]
        let document = try? await AppDomainRuntimeComposition.shared.oracleConversationStore.load(
            groupID: key.groupID,
            owner: key.owner
        )
        guard !Task.isCancelled, isCurrentOracleProjection(session) else { return }
        if let document {
            recordOracleGroupPresentation(document)
        } else if oracleGroupPresentations[key] == previous, previous?.invocationID == nil {
            // A failed fresh read cannot prove the cached turn is still current. Do not, however,
            // erase a newer runtime publication that arrived while this read was suspended.
            oracleGroupPresentations.removeValue(forKey: key)
        }
    }

    func finishOracleGroupPresentation(invocationID: UUID) async {
        guard let entry = oracleGroupPresentations.first(where: { $0.value.invocationID == invocationID }) else { return }
        var ended = entry.value
        ended.endExecution()
        oracleGroupPresentations[entry.key] = ended
        // Runtime catch settlement may already have published failure/cancellation before throwing.
        // Read independently of caller cancellation, matching the runtime's terminal publication.
        // If publication also failed, the prepared projection stays unknown, never successful/live.
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        let groupID = entry.key.groupID
        let owner = entry.key.owner
        let document = try? await Task.detached(priority: Task.currentPriority) {
            try await store.load(groupID: groupID, owner: owner)
        }.value
        if let document {
            recordOracleGroupPresentation(document)
        }
        pruneOracleGroupPresentations()
    }

    func pruneOracleGroupPresentations() {
        let retained = Set(sessions.compactMap(OracleGroupPresentation.Key.init(session:)))
        let next = oracleGroupPresentations.filter { retained.contains($0.key) || $0.value.invocationID != nil }
        if next.count != oracleGroupPresentations.count { oracleGroupPresentations = next }
    }

    private func isCurrentOracleProjection(_ session: ChatSession) -> Bool {
        sessions.contains {
            $0.id == session.id && $0.shortID == session.shortID
                && $0.workspaceID == session.workspaceID && $0.composeTabID == session.composeTabID
                && $0.oracleGroupID == session.oracleGroupID && $0.oracleLaneIndex == session.oracleLaneIndex
                && $0.oracleGroupSize == session.oracleGroupSize && $0.oracleModelRaw == session.oracleModelRaw
        }
    }
}
