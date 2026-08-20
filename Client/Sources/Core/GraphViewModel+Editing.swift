import Foundation
import SwiftUI

// MARK: - Graph editing (mutations proxied to the selected Totem node)

extension GraphViewModel {

    func rename(entityId: String, to name: String) {
        mutate { api in try await api.renameEntity(id: entityId, name: name) }
    }

    func merge(entityId: String, into targetId: String) {
        mutate { api in try await api.mergeEntities(from: entityId, into: targetId) }
    }

    func delete(entityId: String) {
        selectedEntityId = nil
        mutate { api in try await api.deleteEntity(id: entityId) }
    }

    func setKind(entityId: String, kind: String) {
        mutate { api in try await api.setEntityKind(id: entityId, kind: kind) }
    }

    func delete(relationshipId: String) {
        mutate { api in try await api.deleteRelationship(id: relationshipId) }
    }

    func reExtract(documentId: String) {
        mutate { api in try await api.reExtract(documentId: documentId, ownerId: self.ownerId) }
    }

    private func mutate(_ operation: @escaping (TotemAPI) async throws -> GraphMutationResponse) {
        guard let api else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await operation(api)
                await self.fetch()
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}
