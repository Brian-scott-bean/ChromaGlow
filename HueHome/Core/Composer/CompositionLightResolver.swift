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
            let ids = childResourceRefs
                .filter { $0.rtype == "light" }
                .map(\.rid)
            // Zone refs can outlive their lights (a deleted bulb leaves a
            // ghost rid that black-holes its share of the render) — intersect
            // with the live set when one is supplied, preserving ref order
            // (positional per-light colors, M-04). Empty `lights` keeps the
            // historic pass-through for callers with nothing to intersect
            // against (audit L-29).
            guard !lights.isEmpty else { return ids }
            let live = Set(lights.map(\.id))
            return ids.filter { live.contains($0) }
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
