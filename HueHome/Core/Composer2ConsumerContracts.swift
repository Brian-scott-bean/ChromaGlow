// Composer2ConsumerContracts.swift
// ChromaGlow — Core
//
// Composer 2 Phase 1C4: the typed INPUT contract a future resolver receives.
//
// A registration describes what an origin CAN express (Phase 1C3). A request
// describes what an origin IS presenting right now. Keeping the two apart is
// the whole point of this file: capability is static and keyed by origin, a
// request is one concrete semantic action with the facts that were actually
// available at the boundary where it was made.
//
// This file states a request. It does NOT answer whether the request is
// allowed, who wins, who outranks whom, whether another producer must be
// replaced, whether coexistence is permitted, which transport should be
// chosen, how long ownership lasts, whether a stop executes, or how runtime
// state is mutated. Every one of those is arbitration policy, and the resolver
// packet — not this one — is where they are decided.
//
// It also carries no command payload. Brightness, xy, mirek, gradients, effect
// parameters, frame buffers, scene ids, preset ids, transition durations and
// request bodies are execution data; a resolver needs none of them to decide,
// and admitting them would make this contract a second command type.
//
// Written in terms of the accepted Phase 1C2/1C2-a/1C3 vocabulary. Nothing
// here changes it. No production runtime constructs any of these values yet.
//
// Every type is a pure value: no imports, no UI, no networking, no
// concurrency, no persistence, no mutable state, no side effects.

// MARK: - Individual light identity

/// One light in the Hue REST resource namespace.
///
/// Deliberately NOT a universal light id. Phase 1C2 declined to introduce one
/// because production addresses individual lights through two namespaces that
/// are not interchangeable: REST writes go to `/clip/v2/resource/light/{id}`
/// with a String resource id, while Entertainment addresses `UInt8` channel
/// indices inside an already-running stream. The same number in both spaces
/// means two different things.
///
/// Every individual-light write on today's call graph is the REST one, so this
/// type is named for that namespace and is confined to it. An Entertainment
/// channel is not expressible here and must not be spelled as one — that is
/// precisely the conflation 1C2 refused, and it stays refused.
///
/// It lives in the consumer layer rather than in the accepted domain
/// vocabulary on purpose: it describes what a REQUEST can name, and adding a
/// light identity to `Composer2Domain.swift` would read as the universal
/// identity this project has twice declined to invent.
struct Composer2RESTLightIdentity: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Target

/// WHAT a concrete request concerns.
///
/// Four cases, one per resource shape production actually addresses. Nothing
/// is widened to make the set look symmetric, and no case invents a placeholder
/// id to fill a field the call path never had.
///
/// `restLight` names a bridge and a light and stops there. It does NOT name a
/// containing room, because whether writing one bulb implicates the group
/// around it is an arbitration question with no answer yet — inferring the room
/// here would silently decide it.
///
/// `bridge` is the entertainment/observation shape. It is the truthful target
/// for streaming acquisition because production's gate is per-BRIDGE
/// (`canAcquireEntertainment(onBridge:)`), not per-configuration; the
/// configuration identifies the resulting SESSION and lives in
/// `Composer2SessionIdentity`, never here.
///
/// `wholeSystem` carries no payload because the paths that use it carry none:
/// All Off sweeps every bridge and All-Day sweeps every room on every eligible
/// bridge, neither naming a bridge or a group at any point.
enum Composer2ConsumerTarget: Hashable, Sendable {
    case group(Composer2GroupScope)
    case restLight(bridge: Composer2BridgeIdentity,
                   light: Composer2RESTLightIdentity)
    case bridge(Composer2BridgeIdentity)
    case wholeSystem
}

// MARK: - Transport state

/// Whether THIS request is already bound to a transport.
///
/// A fact about one concrete request, and nothing else. It is not a preference,
/// not a ranking, not a fallback chain, and there is no "automatic" case —
/// choosing a transport is selection policy, which this contract refuses to
/// encode exactly as the accepted vocabulary does.
///
/// The distinction is real and load-bearing. A composition start does not know
/// its transport when it is made: the per-bridge acquisition gate runs first
/// and the decision lands on Entertainment or REST afterwards. Other requests
/// are bound before they are presented. Those are materially different states,
/// so they get an explicit case each rather than a magic value or an optional
/// whose nil would have to mean two things.
///
/// `selected` means the transport is bound for THIS request instance. It is
/// never inferred from `Composer2ProducerRegistration.reachableTransports`:
/// reach is capability, and a capability is not a selection.
enum Composer2ConsumerTransportState: Hashable, Sendable {
    /// No transport has been chosen for this request yet.
    case notSelected
    /// This request is bound to this transport.
    case selected(Composer2Transport)
}

// MARK: - Intent request

/// One concrete semantic action being presented.
///
/// Reuses `Composer2ProducerIntent` rather than declaring a second, nearly
/// identical operation enum. The audit found no semantic mismatch: every
/// non-stop action a producer presents is one of the registered intent kinds,
/// so a parallel vocabulary would be two names for one idea and a standing
/// invitation for them to drift.
///
/// There is deliberately no field naming a current owner, a winner, a priority,
/// a rank, a replacement, a coexistence rule, a contention, or a resolution.
/// Those are the resolver's input state or its output, never the request.
///
/// It also embeds no `Composer2ProducerRegistration` and duplicates no
/// capability set. A resolver that needs the registration can receive or look
/// it up separately; copying it into every request would let a stale snapshot
/// travel with the work.
struct Composer2IntentRequest: Hashable, Sendable {

    /// Where this request ORIGINATED. The accepted canonical origin — this
    /// packet introduces no second producer identity and no `delegatesTo`,
    /// because several origins hand their work to another subsystem and the
    /// origin is still the origin when they do.
    let producer: Composer2Producer

    /// The semantic operation being attempted.
    let intent: Composer2ProducerIntent

    /// The resource this request concerns.
    let target: Composer2ConsumerTarget

    /// Whether a transport is bound for this request yet.
    let transport: Composer2ConsumerTransportState

    /// The identity-bearing session instance this request belongs to.
    ///
    /// `nil` means exactly one thing: this request carries no session
    /// instance. It is not a claim that the producer never bears one —
    /// `Composer2ProducerRegistration.identityBearingSessionNamespaces`
    /// already answers that, and reading it off a request would be duplicating
    /// registration. A registration NAMESPACE is never promoted into an
    /// instance to fill this field.
    let session: Composer2SessionIdentity?

    /// A staleness reading taken when this request was made.
    ///
    /// `nil` means this request carries no counter. Most producers have none;
    /// the ones that do capture a generation and re-check it later, which is
    /// the shape this field records. Domains stay distinct — no reading is
    /// widened, narrowed, or compared across counters — and carrying one here
    /// decides nothing: whether stale work proceeds belongs to the resolver or
    /// to the existing runtime until migration.
    let counter: Composer2Counter?

    init(producer: Composer2Producer,
         intent: Composer2ProducerIntent,
         target: Composer2ConsumerTarget,
         transport: Composer2ConsumerTransportState,
         session: Composer2SessionIdentity? = nil,
         counter: Composer2Counter? = nil) {
        self.producer = producer
        self.intent = intent
        self.target = target
        self.transport = transport
        self.session = session
        self.counter = counter
    }
}

// MARK: - Stop request

/// One concrete stop being presented.
///
/// A separate variant rather than an extra `Composer2ProducerIntent` case. A
/// stop names what to END, and `Composer2StopScope` already says that exactly —
/// including the "this group, whichever bridge hosts it" request that an
/// ordinary target cannot express. Forcing a stop through the intent vocabulary
/// would need a target it does not have and would lose that distinction.
///
/// It carries no transport, because no stop path in production names one: a
/// stop says what ends, not how the ending is delivered.
///
/// Whether the stop is permitted, whether it may cross producers, and whether
/// it actually executes are all runtime policy and are not decided here.
struct Composer2StopRequest: Hashable, Sendable {

    /// Where the stop ORIGINATED — not who is being stopped. This contract
    /// names no victim; identifying one would be an arbitration decision.
    let producer: Composer2Producer

    /// What this stop names.
    let scope: Composer2StopScope

    /// The session instance this stop belongs to, if it has one. `nil` carries
    /// the same meaning as on an intent request.
    let session: Composer2SessionIdentity?

    /// A staleness reading taken when this stop was made, if one existed.
    let counter: Composer2Counter?

    init(producer: Composer2Producer,
         scope: Composer2StopScope,
         session: Composer2SessionIdentity? = nil,
         counter: Composer2Counter? = nil) {
        self.producer = producer
        self.scope = scope
        self.session = session
        self.counter = counter
    }
}

// MARK: - Request envelope

/// What a consumer presents for future resolution.
///
/// Two variants because production presents two materially different things:
/// semantic work aimed at a resource, and a stop aimed at a scope. A single
/// flattened struct would need an optional target and an optional stop scope
/// with an unwritten rule that exactly one is set — a rule the type system can
/// enforce for free by keeping them apart.
enum Composer2ConsumerRequest: Hashable, Sendable {
    case intent(Composer2IntentRequest)
    case stop(Composer2StopRequest)
}
