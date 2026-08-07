// Composer2Domain.swift
// ChromaGlow — Core
//
// Composer 2 Phase 1C2: the canonical typed vocabulary.
//
// This file NAMES things. It does not do things. Every type here is a pure
// value: no imports, no UI, no networking, no concurrency, no persistence, no
// global state, no side effects. Nothing in production consumes any of it yet
// — consumers arrive with the registration and resolver packets.
//
// It describes identity and decisions. It deliberately does NOT decide:
// producer precedence, transport selection, how long a producer owns a room,
// whether two producers may coexist, or when one runtime may stop another.
// Those remain open product policy. Where a canonical shape would have forced
// one of those answers, the concept is left out rather than guessed.
//
// It also does not replace anything. Every existing runtime type — the REST
// scope and its owner, the Entertainment requester, the playback and ownership
// keys, the six transport enums, every generation counter — stays exactly as
// it is. This vocabulary is what later contracts will be written in terms of.

// MARK: - Resource identity

/// Which bridge a resource belongs to.
///
/// Production spells "no identified bridge" three incompatible ways today: a
/// nil optional, the string "legacy", and the empty string. Making the
/// bridgeless condition a CASE rather than a sentinel is the whole point — it
/// can never collide with a real bridge whose id happens to be one of those
/// spellings, and there is no normalization step in which two subsystems can
/// disagree about which spelling they meant.
enum Composer2BridgeIdentity: Hashable, Sendable {
    case bridge(String)
    case unidentified
}

/// A light group: the resource an intent targets.
///
/// Rooms and zones stay distinct because production distinguishes them, even
/// though the REST scope collapses both into a bare room id. Collapsing them
/// here would throw away a distinction the app can still make.
enum Composer2GroupIdentity: Hashable, Sendable {
    case room(String)
    case zone(String)
}

/// A group ON a bridge.
///
/// Composed from two identities rather than concatenated into a string: there
/// is no separator to collide with, and no magic bridge value to normalize.
/// The same group id on two identified bridges is two different scopes.
///
/// Named GROUP scope deliberately. It is not the only scope arbitration will
/// ever need — work identified by bridge and entertainment configuration is
/// described by `Composer2SessionIdentity`, not by this type.
struct Composer2GroupScope: Hashable, Sendable {
    let bridge: Composer2BridgeIdentity
    let group: Composer2GroupIdentity

    init(bridge: Composer2BridgeIdentity, group: Composer2GroupIdentity) {
        self.bridge = bridge
        self.group = group
    }
}

/// An entertainment configuration id.
///
/// A separate namespace from group ids on purpose: production keys
/// entertainment ownership by configuration, never by room, and the two id
/// spaces are not interchangeable even when two ids read the same.
struct Composer2ConfigurationIdentity: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Producer identity

/// Where an intent ORIGINATED.
///
/// A case means "this intent came from here". It does NOT mean "this producer
/// owns the scope", "this producer wins", or "this producer outranks another".
/// There is deliberately no ordering, no ranking, and no comparison: precedence
/// between producers is unresolved product policy, and encoding it here would
/// answer a question this packet is not allowed to answer.
///
/// The list is wider than any single existing owner enum because the audited
/// writer set is wider: four of these produce light state today without
/// carrying any ownership token at all, and one of them is not this app.
enum Composer2Producer: Hashable, Sendable, CaseIterable {
    case composer
    case studio
    case allDay
    case widget
    case siri
    case watch
    case manual
    case foreignController
}

// MARK: - Transport identity

/// HOW an intent reaches the lights.
///
/// These are delivery categories — what actually carried the frames — not
/// preferences. The "automatic" option of the preference enums is absent on
/// purpose: choosing a transport IS the selection policy, and this vocabulary
/// describes transports without choosing between them.
///
/// Domain-level and independent of presentation: no titles, no labels, no
/// symbols. The user-facing wording for these concepts lives in the UI copy
/// namespace and is not duplicated here.
enum Composer2Transport: Hashable, Sendable, CaseIterable {
    case entertainment
    case rest
    case bridgeStored
    case oneShot
}

// MARK: - Staleness counters

/// A staleness counter reading, tagged with the counter it came from.
///
/// Production runs six independent counters with genuinely different
/// representations, and no two of them are ever compared to each other. Each
/// case here therefore carries its own counter's NATIVE type — five are Int,
/// one is UInt64 — so a reading is never widened, narrowed, or sign-converted
/// to fit a common field. The signed cases can still hold the negative
/// "never seen" value a consumer mirror uses today, which an unsigned
/// representation could not express at all.
///
/// There is deliberately no shared numeric accessor and no raw value.
/// Exposing one would hand callers back exactly the cross-counter comparison
/// this type exists to refuse. Two readings are equal only when they came from
/// the same counter AND carry the same value.
///
/// This describes counters. It does not unify them, replace them, or change
/// any staleness rule.
enum Composer2Counter: Hashable, Sendable {
    case compositionPlayback(Int)
    case allDayPlayback(Int)
    case restScopeEpoch(UInt64)
    case bridgeNativeOwnership(Int)
    case roomOwnership(Int)
    case bridgeAnimationReconcile(Int)
}

// MARK: - Session identity

/// One unit of work a producer started, named in the namespace that actually
/// identifies it.
///
/// The two session namespaces production maintains do not share a key shape.
/// An entertainment session is identified by a bridge plus the entertainment
/// CONFIGURATION it streams to, and names no group at all. A Composer REST
/// telemetry session is identified by a group scope plus the producer writing
/// it, and names no configuration. Flattening either into the other would
/// require inventing identifying data that does not exist, so neither is
/// flattened and no synthetic session number is introduced.
enum Composer2SessionIdentity: Hashable, Sendable {
    case entertainment(bridge: Composer2BridgeIdentity,
                       configuration: Composer2ConfigurationIdentity)
    case restTelemetry(scope: Composer2GroupScope,
                       producer: Composer2Producer)
}

// MARK: - Contention

/// Why a resolution is not a plain "proceed".
///
/// Every case states a FACT about the scope: something is held, something is
/// unavailable, something could not be read. No case ranks producers, names a
/// winner, or carries a duration. Which fact should win is the arbitration
/// policy this vocabulary refuses to encode.
enum Composer2Contention: Hashable, Sendable {
    /// Held by the named producer. `foreignController` covers a controller
    /// outside this app, so no second spelling of that fact is needed.
    case heldByProducer(Composer2Producer)
    case transportUnavailable(Composer2Transport)
    case capacityInsufficient
    /// The evidence needed to decide could not be read. Never a synonym for
    /// "free" and never a synonym for "empty": unknown is not verified.
    case evidenceUnreadable
    /// The request refers to work that has already been replaced or ended.
    case superseded
}

// MARK: - Resolution

/// The SHAPE of a future resolver's answer.
///
/// Domain data only: no closures, no tasks, no clients, no messages, no UI
/// state. There is no failure case, because executing can fail but resolving
/// cannot — a failed write is an outcome of acting on a resolution, not a
/// resolution.
///
/// `proceed` deliberately names no transport. Which transport carries an
/// intent is selection policy; this vocabulary says only whether to proceed.
///
/// The cases are the outcome categories production already produces, spelled
/// neutrally. Categories that would have to be invented to make the set look
/// symmetric are absent.
enum Composer2Resolution: Hashable, Sendable {
    case proceed
    /// The requested state already holds. Nothing to do is a success.
    case nothingToDo
    case requiresRelease(of: Composer2Producer, because: Composer2Contention)
    case requiresUserDecision(about: Composer2Contention)
    case refuse(because: Composer2Contention)
    /// Not resolvable on the evidence available. Distinct from a refusal:
    /// nothing was proven, so nothing may be assumed.
    case undetermined(Composer2Contention)
}

// MARK: - Stop targeting

/// What a stop request names.
///
/// `anyBridgeHosting` is the "this group, whichever bridge hosts it" request
/// one production call site expresses today with a nil bridge id. That is a
/// DIFFERENT condition from a scope whose bridge is `.unidentified`, which
/// means the group has no identified bridge at all — two meanings that share
/// one spelling in production and are separated here.
///
/// How an ambiguous request is resolved, and whether a stop may cross
/// producers, is runtime policy and is not decided by this type.
enum Composer2StopScope: Hashable, Sendable {
    case exact(Composer2GroupScope)
    case anyBridgeHosting(Composer2GroupIdentity)
    case everything
}
