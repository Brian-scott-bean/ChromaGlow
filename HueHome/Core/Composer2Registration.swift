// Composer2Registration.swift
// ChromaGlow — Core
//
// Composer 2 Phase 1C3: policy-neutral producer registration contracts.
//
// A registration DESCRIBES a producer. It does not arbitrate between producers.
// It answers "who originated this, and what can an intent from there currently
// cause?" — never "who wins", "who has priority", "how long ownership lasts",
// "may these coexist", "which transport should be selected", or "should this
// stop execute". Those remain unresolved product policy, and every field here
// was chosen so that none of them can be smuggled in.
//
// Keyed by ORIGIN. `Composer2Producer` means where an intent came from, and
// nothing here overloads it into an executor or subsystem identity. That
// distinction is load-bearing: several origins delegate their work to another
// subsystem, and this file records what the ORIGIN can reach, never who
// carried it out.
//
// Written in terms of the accepted Phase 1C2/1C2-a vocabulary. Nothing here
// changes it, and no production runtime consumes any of this yet — consumers
// arrive with the typed-consumer and resolver packets.
//
// Every type is a pure value: no imports, no UI, no networking, no
// concurrency, no persistence, no mutable state, no side effects.

// MARK: - Provenance

/// Where a registration's FACTS came from.
///
/// This is not a ranking and not a permission. It records how much the app can
/// actually know about a producer, which differs in kind between the eight
/// producers this app originates and the one it merely observes.
///
/// The distinction also settles precisely how an absent capability reads, so no
/// three-state capability system is needed:
///
///   • `originatedInApp` — every entry point is enumerable, so absence from a
///     set below IS evidence of absence.
///   • `observedExternally` — the sets record only what production observes.
///     Absence is NOT evidence of absence; they are a floor, not a description.
enum Composer2RegistrationProvenance: Hashable, Sendable, CaseIterable {
    case originatedInApp
    case observedExternally
}

// MARK: - Intents

/// A KIND of semantic operation an intent can cause.
///
/// Every case is tied to a real current entry point. A producer registers a
/// case when an intent originating there can cause it through today's actual
/// call graph — whether the origin performs the write itself or hands the
/// request to another subsystem. Reach is reach; who executes it is not what
/// this vocabulary describes.
///
/// Deliberately absent: any case that would encode precedence, exclusivity, or
/// permission. There is no "may override", no "exclusive", no "owner".
enum Composer2ProducerIntent: Hashable, Sendable, CaseIterable {
    /// Set on / brightness / color / colour temperature on a group.
    case groupState
    /// The same, addressed to one light rather than a group.
    case lightState
    /// ACTIVATE the bridge's own effects field. Clearing that field is a stop,
    /// not an activation, and is described by `Composer2RegistrationStopKind`
    /// instead — a clearing write is never evidence of activation capability.
    case bridgeFirmwareEffect
    /// Activate a scene the bridge already stores.
    case sceneRecall
    /// An ongoing stream of frames.
    case continuousStreaming
    /// Upload work to the bridge AND start the bridge running it itself.
    /// Registering this requires reaching an activation path, not merely a
    /// save: uploading a program the bridge never runs is not playback.
    case bridgeStoredPlayback
}

// MARK: - Scope kinds

/// The SHAPE of resource an origin can address.
///
/// Kinds, never instances. No case carries a payload, so a registration
/// physically cannot store a room id, a zone id, or a bridge id — a static
/// catalog describing capability must not name live resources.
///
/// `unidentifiedBridge` means the origin can address work whose bridge is not
/// identified. It is not a claim about resolving an ambiguous request; that
/// distinction lives in `Composer2RegistrationStopKind.anyBridgeHosting`.
enum Composer2RegistrationScopeKind: Hashable, Sendable, CaseIterable {
    case room
    case zone
    case identifiedBridge
    case unidentifiedBridge
    case wholeSystem
}

// MARK: - Session namespaces

/// A session NAMESPACE in which current runtime state actually preserves the
/// registering origin's identity.
///
/// The bar is deliberately high: a scheduling or mailbox key that merely
/// happens to be tagged with an owner does NOT qualify. The namespace must be
/// represented by real session state that retains which producer it belongs
/// to. Several origins write light state today while participating in no
/// session at all, and that fact is worth being able to state.
///
/// Namespaces, never instances: no bridge, no configuration, no session id.
enum Composer2RegistrationSessionNamespace: Hashable, Sendable, CaseIterable {
    case entertainment
    case restTelemetry
}

// MARK: - Stop kinds

/// What a stop request originating here can NAME.
///
/// Mirrors the three shapes of `Composer2StopScope` as kinds, without their
/// payloads. It says nothing about whether a stop is permitted, whether it may
/// cross producers, or whether it will succeed.
///
/// `anyBridgeHosting` is the "this group, whichever bridge hosts it" request —
/// genuinely distinct from an exact scope whose bridge is unidentified.
enum Composer2RegistrationStopKind: Hashable, Sendable, CaseIterable {
    case exactScope
    case anyBridgeHosting
    case everything
}

// MARK: - Registration

/// What one producer can currently express.
///
/// Description only. There is no ordering, no `Comparable`, no rank, and no
/// field naming a winner — two registrations can be compared for equality and
/// nothing else, because "which of these two should proceed" is exactly the
/// question this contract refuses to answer.
///
/// It is also not a consumer request. There is deliberately no target, no
/// requested transport, no generation, no session instance, no current owner,
/// and no action payload: those belong to the typed-consumer packet.
struct Composer2ProducerRegistration: Hashable, Sendable {

    /// The accepted canonical origin. Registration introduces no second
    /// identity namespace for the nine producers.
    let producer: Composer2Producer

    /// How much this registration can claim to know.
    let provenance: Composer2RegistrationProvenance

    /// Semantic operations an intent from this origin can currently cause,
    /// directly or by delegation.
    let intents: Set<Composer2ProducerIntent>

    /// Resource shapes this origin can address. Shapes only.
    let scopeKinds: Set<Composer2RegistrationScopeKind>

    /// Transports an intent from this origin can actually reach today,
    /// directly or by delegation. Descriptive: no ordering, no preference, no
    /// fallback chain, and no "automatic" — choosing a transport is selection
    /// policy and is not decided here.
    let reachableTransports: Set<Composer2Transport>

    /// Session namespaces whose runtime state retains this origin's identity.
    /// Empty is a real and common answer.
    let identityBearingSessionNamespaces: Set<Composer2RegistrationSessionNamespace>

    /// Stop shapes an intent from this origin can currently express.
    let stopKinds: Set<Composer2RegistrationStopKind>

    init(producer: Composer2Producer,
         provenance: Composer2RegistrationProvenance,
         intents: Set<Composer2ProducerIntent>,
         scopeKinds: Set<Composer2RegistrationScopeKind>,
         reachableTransports: Set<Composer2Transport>,
         identityBearingSessionNamespaces: Set<Composer2RegistrationSessionNamespace>,
         stopKinds: Set<Composer2RegistrationStopKind>) {
        self.producer = producer
        self.provenance = provenance
        self.intents = intents
        self.scopeKinds = scopeKinds
        self.reachableTransports = reachableTransports
        self.identityBearingSessionNamespaces = identityBearingSessionNamespaces
        self.stopKinds = stopKinds
    }
}

// MARK: - Catalog

/// The nine producers as they behave in current production code.
///
/// Immutable data and nothing else: an uninhabited namespace holding one
/// `static let` array. It performs no work, owns no mutable state, starts
/// nothing, and no production runtime reads it in this packet.
///
/// Each entry is an audit result. Where two producers differ, they differ
/// because the code differs — All-Day cannot address a zone, automation cannot
/// address an unidentified bridge, and widget and watch cannot stop anything.
enum Composer2ProducerRegistrationCatalog {

    static let observed: [Composer2ProducerRegistration] = [

        // Composer runs a room's composition. Its per-light writes are STATE
        // writes with a transition, not firmware effects. It reaches no
        // bridge-stored playback: the save is a Studio surface action, and the
        // bridge-stored arm inside the composition start is unreachable on
        // today's call graph. Its stop always names an exact bridge+room — a
        // nil bridge there normalizes to the bridgeless identity rather than
        // asking "whichever bridge hosts it".
        Composer2ProducerRegistration(
            producer: .composer,
            provenance: .originatedInApp,
            intents: [.groupState, .lightState, .continuousStreaming],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge],
            reachableTransports: [.rest, .entertainment, .oneShot],
            identityBearingSessionNamespaces: [.entertainment, .restTelemetry],
            stopKinds: [.exactScope]),

        // Studio is the only origin that reaches bridge-stored PLAYBACK: the
        // tray save both uploads the chain and then starts it. Its REST state
        // is a record of which scope owns each bridge, not a telemetry
        // session, so only the entertainment namespace bears its identity.
        Composer2ProducerRegistration(
            producer: .studio,
            provenance: .originatedInApp,
            intents: [.groupState, .bridgeFirmwareEffect, .continuousStreaming,
                      .bridgeStoredPlayback],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .entertainment, .bridgeStored, .oneShot],
            identityBearingSessionNamespaces: [.entertainment],
            stopKinds: [.exactScope, .everything]),

        // All-Day sweeps every room on every eligible bridge on a cadence. It
        // never reads the zone list, so it cannot address one. It owns no
        // session: a mailbox scope tagged with its name is scheduling
        // ownership, not session identity. Its stop is all-or-nothing.
        Composer2ProducerRegistration(
            producer: .allDay,
            provenance: .originatedInApp,
            intents: [.groupState],
            scopeKinds: [.room, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest],
            identityBearingSessionNamespaces: [],
            stopKinds: [.everything]),

        // A scheduled automation firing. The narrowest scope of any in-app
        // origin: its bulk writer walks rooms only and requires a resolved
        // client, so neither a zone nor an unidentified bridge is reachable.
        // It carries no session and contains no stop.
        Composer2ProducerRegistration(
            producer: .automation,
            provenance: .originatedInApp,
            intents: [.groupState, .bridgeFirmwareEffect],
            scopeKinds: [.room, .identifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .oneShot],
            identityBearingSessionNamespaces: [],
            stopKinds: []),

        // The widget extension writes straight to the bridge from its own
        // process. Its "all off" is a bare power write, not an effect stop.
        Composer2ProducerRegistration(
            producer: .widget,
            provenance: .originatedInApp,
            intents: [.groupState, .sceneRecall],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .oneShot],
            identityBearingSessionNamespaces: [],
            stopKinds: []),

        // Siri writes directly for simple control and DELEGATES its Studio and
        // Composer intents through a pending-action handoff. Reach counts, so
        // the delegated firmware activation and the delegated stream are both
        // registered. Identity does NOT survive that handoff — the session that
        // results records Studio or Composer, never Siri — so it bears no
        // session identity despite reaching Entertainment. Its stop names the
        // whole home and cannot name one room.
        Composer2ProducerRegistration(
            producer: .siri,
            provenance: .originatedInApp,
            intents: [.groupState, .lightState, .bridgeFirmwareEffect,
                      .sceneRecall, .continuousStreaming],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .entertainment, .oneShot],
            identityBearingSessionNamespaces: [],
            stopKinds: [.everything]),

        // The watch app writes to the bridge itself over the LAN. It has no
        // path back to the phone, so it can stop nothing.
        Composer2ProducerRegistration(
            producer: .watch,
            provenance: .originatedInApp,
            intents: [.groupState, .sceneRecall],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .oneShot],
            identityBearingSessionNamespaces: [],
            stopKinds: []),

        // Direct control from the app's own surfaces. The only origin besides
        // Composer that addresses an individual light, and the only one that
        // can name a group without naming its bridge.
        Composer2ProducerRegistration(
            producer: .manual,
            provenance: .originatedInApp,
            intents: [.groupState, .lightState, .sceneRecall],
            scopeKinds: [.room, .zone, .identifiedBridge, .unidentifiedBridge, .wholeSystem],
            reachableTransports: [.rest, .oneShot],
            identityBearingSessionNamespaces: [],
            stopKinds: [.exactScope, .anyBridgeHosting]),

        // Not this app. Everything here is read off a bridge: one active
        // entertainment configuration that ChromaGlow did not record. The
        // bridge names no room and no vendor, so no scope beyond the bridge
        // and no other intent can be claimed. Its stop set is empty because it
        // issues no stop to us — the consent-bound stop of a third-party
        // session is a request WE originate, not a capability it has here.
        //
        // Its provenance marks these sets as a floor: absence is not evidence
        // of absence for a producer we can only observe.
        Composer2ProducerRegistration(
            producer: .foreignController,
            provenance: .observedExternally,
            intents: [.continuousStreaming],
            scopeKinds: [.identifiedBridge],
            reachableTransports: [.entertainment],
            identityBearingSessionNamespaces: [.entertainment],
            stopKinds: []),
    ]
}
