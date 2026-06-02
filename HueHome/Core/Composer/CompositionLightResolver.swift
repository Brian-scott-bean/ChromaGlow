import Foundation

enum CompositionLightResolver {
    static func hasDirectLightReferences(
        childResourceRefs: [(rid: String, rtype: String)]
    ) -> Bool {
        childResourceRefs.contains { $0.rtype == "light" }
    }

    static func resolveLights(
        childResourceRefs: [(rid: String, rtype: String)],
        lights: [HueLight]
    ) -> [HueLight] {
        if hasDirectLightReferences(childResourceRefs: childResourceRefs) {
            let directLightIDs = Set(
                childResourceRefs
                    .filter { $0.rtype == "light" }
                    .map(\.rid)
            )
            return lights.filter { directLightIDs.contains($0.id) }
        }

        let deviceIDs = Set(childResourceRefs.map(\.rid))
        return lights.filter { light in
            guard let ownerRID = light.owner?.rid else { return false }
            return deviceIDs.contains(ownerRID)
        }
    }

    static func resolveLightIDs(
        childResourceRefs: [(rid: String, rtype: String)],
        lights: [HueLight]
    ) -> [String] {
        if hasDirectLightReferences(childResourceRefs: childResourceRefs) {
            return childResourceRefs
                .filter { $0.rtype == "light" }
                .map(\.rid)
        }

        let deviceIDs = Set(childResourceRefs.map(\.rid))
        return lights
            .filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
            .map(\.id)
    }
}
