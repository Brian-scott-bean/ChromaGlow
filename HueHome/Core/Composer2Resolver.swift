// Composer2Resolver.swift
// ChromaGlow — Core
//
// Composer 2 Phase 1D: the pure resolver seam.
//
// This file DECIDES nothing about the world. It is one total function from a
// typed request plus typed observed facts to a typed answer, and returning
// that answer is the whole of its effect. It starts nothing, stops nothing,
// acquires nothing, releases nothing, enqueues nothing, cancels nothing,
// mutates nothing, posts nothing, reads no storage and no feature switch, and
// touches no UI state. No production runtime consumes it.
//
// It deliberately does NOT answer: which producer outranks which, which
// transport should carry an intent, how long a producer owns a resource,
// whether two producers may coexist, whether a replacement happens
// automatically, or when one runtime may end another runtime's work. Those
// remain open product policy. Where an answer would have required one of
// them, the seam returns an accepted undetermined or refusal shape and says
// so, rather than guessing.
//
// Two disciplines carry most of the weight here:
//
//   1. Evidence QUALITY is in the type system. Production reads produce four
//      genuinely different answers — here is the fact, there is no such fact,
//      no record of this kind exists, the read failed — and an optional can
//      spell only two of them. Collapsing them is how "could not read" turns
//      into "free", which is exactly the mistake this seam exists to refuse.
//
//   2. Staleness counters are read PER DOMAIN. The six counters were kept
//      distinct on purpose and they do not share semantics: five of them are
//      captured-token-against-live-generation comparisons whose mismatch means
//      the captured work is no longer current, and one of them is a hydration
//      watermark whose comparison runs the other way round — a DIFFERENCE
//      means there is new work to absorb. Applying one equality rule to all
//      six would state that sixth domain's meaning backwards.
//
// Every type here is a pure value: no imports, no UI, no networking, no
// concurrency, no persistence, no global state, no side effects.

// MARK: - Evidence

/// HOW WELL one fact about a resource is known.
///
/// Four cases because production produces four genuinely different answers and
/// they must never collapse into each other:
///
///   • `observed`    — read successfully; here is the fact.
///   • `absent`      — read successfully; the target has no such fact now.
///   • `unsupported` — the runtime keeps no record of this kind for a resource
///                     of this shape at all. Six of the nine registered
///                     origins participate in no session whatever, and no
///                     production record is keyed by an individual light.
///                     Never a synonym for `absent`.
///   • `unreadable`  — the read failed. Never a synonym for `absent`, and
///                     never a synonym for free.
///
/// Unknown is not verified. Unsupported is not empty. Neither is permission.
enum Composer2Evidence<Fact: Hashable & Sendable>: Hashable, Sendable {
    case observed(Fact)
    case absent
    case unsupported
    case unreadable
}

// MARK: - Observed state

/// The facts observed about ONE request's target, at the moment it was made.
///
/// Facts only. There is no client, no work handle, no command payload, no
/// interface state, no dictionary, no untyped value, and no capability
/// catalog: a catalog describes what an origin CAN express, which is a
/// different question from what is true of this resource right now, and
/// copying one into the other would let a stale snapshot travel with the work.
///
/// It is scoped to the request's OWN target and invents no universal owner
/// map, because production has none: entertainment holding is recorded per
/// bridge, group driving is recorded across five separate per-room records,
/// and neither is expressible in the other's key shape.
///
/// No field carries a default. Every observation must state its own evidence
/// quality explicitly — a default would smuggle back the silent assumption
/// this type exists to remove.
struct Composer2ObservedState: Hashable, Sendable {

    /// The producer observed driving the request's target.
    ///
    /// `unsupported` is the truthful reading for an individual light: no
    /// production record is keyed by one, so a light's contention is not
    /// merely unknown, it is unrecorded. That must not become "free", and it
    /// must not be answered by reaching for the room around the light —
    /// whether writing one bulb implicates its group has no settled answer.
    let holder: Composer2Evidence<Composer2Producer>

    /// The identity-bearing session observed on the target.
    let session: Composer2Evidence<Composer2SessionIdentity>

    /// The staleness reading the runtime currently holds for the target.
    /// Domains stay distinct: nothing here is widened, narrowed, or
    /// sign-converted to fit a common field.
    let counter: Composer2Evidence<Composer2Counter>

    init(holder: Composer2Evidence<Composer2Producer>,
         session: Composer2Evidence<Composer2SessionIdentity>,
         counter: Composer2Evidence<Composer2Counter>) {
        self.holder = holder
        self.session = session
        self.counter = counter
    }
}

// MARK: - Resolver

/// The seam: one request plus one observation yields one resolution.
///
/// An uninhabited namespace holding pure static functions. It owns no state,
/// keeps no cache, holds no singleton, spawns nothing, and stores no closure.
/// Calling it twice with equal inputs yields equal outputs, forever.
enum Composer2Resolver {

    /// Resolves one presented request against the facts observed about its
    /// target.
    ///
    /// The answer is always one of the six accepted resolution shapes. There
    /// is no failure shape, because executing can fail but resolving cannot,
    /// and `proceed` carries no transport because selecting one is policy this
    /// seam refuses to hold.
    static func resolve(request: Composer2ConsumerRequest,
                        observed: Composer2ObservedState) -> Composer2Resolution {

        // Currency first, uniformly for both request shapes. This ordering is
        // a deliberate normalization, not a claim about current behavior: the
        // stop paths in production check absence before they would consult any
        // generation. A uniform order is what makes this function's totality
        // reviewable, and it errs closed in every case where the two differ.
        switch currency(of: request, against: observed) {
        case .stale:
            return .refuse(because: .superseded)
        case .unprovable:
            return .undetermined(.evidenceUnreadable)
        case .current, .noEvidence:
            break
        }

        switch request {
        case .intent:
            return resolveIntent(observed: observed)
        case .stop(let stop):
            return resolveStop(stop, observed: observed)
        }
    }

    // MARK: Intent

    /// Resolves an intent request.
    ///
    /// It receives no request. That is the point, and it is the structural
    /// proof that no precedence table hides here: an intent's resolution is a
    /// function of the observed holder alone, so the origin cannot influence
    /// it, cannot be compared against the holder, and is not even in scope.
    ///
    /// `requiresRelease` states the NECESSARY CONDITION and stops there — that
    /// hold must end before this request can proceed. It does not say who may
    /// end it, whether ending it is automatic, whether the user is asked, or
    /// who would win if both insisted.
    ///
    /// The one producer named explicitly is named for its PROVENANCE, not its
    /// rank: a controller outside this app cannot be asked to release
    /// anything, and production never ends such a session without an explicit
    /// decision from the person using the app. That is a statement about who
    /// can be asked, and it confers no ordering on anybody.
    ///
    /// `nothingToDo` is unreachable from here by construction: a request
    /// carries no payload, so this function can never know that the requested
    /// state already holds.
    private static func resolveIntent(observed: Composer2ObservedState) -> Composer2Resolution {
        switch observed.holder {
        case .unreadable:
            return .refuse(because: .evidenceUnreadable)
        case .unsupported:
            return .undetermined(.evidenceUnreadable)
        case .absent:
            return .proceed
        case .observed(let holder):
            switch holder {
            case .foreignController:
                return .requiresUserDecision(about: .heldByProducer(.foreignController))
            case .composer, .studio, .allDay, .automation,
                 .widget, .siri, .watch, .manual:
                return .requiresRelease(of: holder, because: .heldByProducer(holder))
            }
        }
    }

    // MARK: Stop

    /// Resolves a stop request.
    ///
    /// A stop is not an intent wearing a different hat, so it is resolved on
    /// its own terms and it is never executed here.
    ///
    /// Two of the three stop shapes are answered `undetermined` on purpose.
    /// The "this group, whichever bridge hosts it" shape names no bridge, and
    /// an observation about one resource cannot be attributed to a bridge the
    /// request never named — resolving it would be exactly the hosting
    /// inference this seam must not perform. The everything shape names no
    /// resource at all, and whether a sweeping stop may reach across origins
    /// is unresolved policy.
    ///
    /// The exact shape compares the origin with the holder for EQUALITY only.
    /// Equality is symmetric and confers no rank: swap which producer
    /// originated the stop and which is holding, and the answer keeps its
    /// shape. Nothing here orders two producers.
    private static func resolveStop(_ request: Composer2StopRequest,
                                    observed: Composer2ObservedState) -> Composer2Resolution {
        switch request.scope {
        case .anyBridgeHosting, .everything:
            return .undetermined(.evidenceUnreadable)
        case .exact:
            switch observed.holder {
            case .unreadable:
                return .refuse(because: .evidenceUnreadable)
            case .unsupported:
                return .undetermined(.evidenceUnreadable)
            case .absent:
                // Nothing to remove is a success, not a failure.
                return .nothingToDo
            case .observed(let holder):
                return holder == request.producer
                    ? .proceed
                    : .undetermined(.heldByProducer(holder))
            }
        }
    }

    // MARK: Currency

    /// What the evidence proves about whether a request is still current.
    private enum Currency: Hashable {
        /// Nothing in this observation bears on the question.
        case noEvidence
        /// The request is proven to still be current.
        case current
        /// The request is proven to name work that has been replaced or ended.
        case stale
        /// Currency could not be established. Nothing is proven, so nothing
        /// may be assumed — which is not the same as being proven stale.
        case unprovable
    }

    /// What a MISMATCH in one counter domain is proven to mean.
    ///
    /// Read domain by domain from the code that actually compares each
    /// counter. The domains were kept separate deliberately and they do not
    /// share semantics, so a single rule across all six would be a fiction.
    private enum CounterDomainSemantics: Hashable {
        /// A mismatch means the captured work is no longer current, AND an
        /// absent current reading means the same: the comparison treats a
        /// missing entry as a mismatch through an explicit branch.
        case supersededOnMismatchAndAbsence
        /// A mismatch means the captured work is no longer current. What an
        /// ABSENT current reading means is NOT proven: one domain defaults a
        /// missing entry to zero on a path a captured reading cannot reach,
        /// one mismatches only by arithmetic coincidence rather than by an
        /// explicit branch, and one is a plain counter that is never absent.
        case supersededOnMismatchOnly
        /// Not a staleness generation at all. Its only comparison is a
        /// hydration watermark held against a mirror, and it runs the other
        /// way round: EQUALITY means there is nothing new to absorb, and a
        /// difference means there is. Reading a mismatch there as "your work
        /// is stale" would state its meaning backwards, so no currency
        /// conclusion is drawn from this domain at all.
        case notAStalenessGeneration
    }

    /// The combined currency verdict for a request.
    ///
    /// A proven staleness outranks an unprovable one: being sure beats being
    /// unsure. Everything else falls through.
    private static func currency(of request: Composer2ConsumerRequest,
                                 against observed: Composer2ObservedState) -> Currency {
        let requestedSession: Composer2SessionIdentity?
        let requestedCounter: Composer2Counter?
        switch request {
        case .intent(let intent):
            requestedSession = intent.session
            requestedCounter = intent.counter
        case .stop(let stop):
            requestedSession = stop.session
            requestedCounter = stop.counter
        }

        let byCounter = counterCurrency(requested: requestedCounter,
                                        observed: observed.counter)
        let bySession = sessionCurrency(requested: requestedSession,
                                        observed: observed.session)

        if byCounter == .stale || bySession == .stale { return .stale }
        if byCounter == .unprovable || bySession == .unprovable { return .unprovable }
        if byCounter == .current || bySession == .current { return .current }
        return .noEvidence
    }

    /// Currency as far as the staleness counters can prove it.
    private static func counterCurrency(requested: Composer2Counter?,
                                        observed: Composer2Evidence<Composer2Counter>) -> Currency {
        guard let requested else { return .noEvidence }

        // The watermark domain short-circuits before any comparison happens,
        // so it can never produce a superseded verdict in any combination.
        switch semantics(of: requested) {
        case .notAStalenessGeneration:
            return .noEvidence
        case .supersededOnMismatchAndAbsence, .supersededOnMismatchOnly:
            break
        }

        switch observed {
        case .unreadable, .unsupported:
            return .unprovable
        case .absent:
            switch semantics(of: requested) {
            case .supersededOnMismatchAndAbsence:
                return .stale
            case .supersededOnMismatchOnly:
                return .unprovable
            case .notAStalenessGeneration:
                return .noEvidence
            }
        case .observed(let current):
            // Two readings from unrelated counters prove nothing about each
            // other and are never compared numerically. There is no common
            // numeric accessor to reach for, and none is added here.
            guard sharesDomain(requested, current) else { return .noEvidence }
            return requested == current ? .current : .stale
        }
    }

    /// Currency as far as session identity can prove it.
    ///
    /// The asymmetry with counters at the absent and unsupported cases is
    /// deliberate and separately evidenced. The counter comparisons contradict
    /// each other about what a missing current reading means, so nothing is
    /// proven there. The session comparisons do not: a session that has ended
    /// before a confirmation lands is treated uniformly as nothing left to
    /// stop, never as a refusal — and the holder field already states that
    /// nothing is there, so restating it as a second refusal would be
    /// double-counting one fact.
    private static func sessionCurrency(requested: Composer2SessionIdentity?,
                                        observed: Composer2Evidence<Composer2SessionIdentity>) -> Currency {
        guard let requested else { return .noEvidence }

        switch observed {
        case .unreadable:
            return .unprovable
        case .absent, .unsupported:
            return .noEvidence
        case .observed(let current):
            guard sharesNamespace(requested, current) else { return .noEvidence }
            return requested == current ? .current : .stale
        }
    }

    // MARK: Domain separation

    /// The proven meaning of a mismatch in each counter domain.
    ///
    /// Exhaustive with no catch-all arm: a seventh counter domain is a compile
    /// error here, which is the only way to guarantee a new domain arrives
    /// with its semantics stated rather than inherited by accident.
    private static func semantics(of counter: Composer2Counter) -> CounterDomainSemantics {
        switch counter {
        case .compositionPlayback:
            return .supersededOnMismatchAndAbsence
        case .bridgeNativeOwnership:
            return .supersededOnMismatchAndAbsence
        case .restScopeEpoch:
            return .supersededOnMismatchOnly
        case .roomOwnership:
            return .supersededOnMismatchOnly
        case .allDayPlayback:
            return .supersededOnMismatchOnly
        case .bridgeAnimationReconcile:
            return .notAStalenessGeneration
        }
    }

    /// Whether two readings came from the same counter.
    ///
    /// The second arm enumerates every domain explicitly rather than using a
    /// catch-all, so adding a domain fails to compile instead of silently
    /// falling into "unrelated".
    private static func sharesDomain(_ lhs: Composer2Counter,
                                     _ rhs: Composer2Counter) -> Bool {
        switch (lhs, rhs) {
        case (.compositionPlayback, .compositionPlayback),
             (.allDayPlayback, .allDayPlayback),
             (.restScopeEpoch, .restScopeEpoch),
             (.bridgeNativeOwnership, .bridgeNativeOwnership),
             (.roomOwnership, .roomOwnership),
             (.bridgeAnimationReconcile, .bridgeAnimationReconcile):
            return true
        case (.compositionPlayback, _),
             (.allDayPlayback, _),
             (.restScopeEpoch, _),
             (.bridgeNativeOwnership, _),
             (.roomOwnership, _),
             (.bridgeAnimationReconcile, _):
            return false
        }
    }

    /// Whether two session identities live in the same namespace.
    ///
    /// The namespaces do not share a key shape, so identities drawn from
    /// different ones are never compared for currency.
    private static func sharesNamespace(_ lhs: Composer2SessionIdentity,
                                        _ rhs: Composer2SessionIdentity) -> Bool {
        switch (lhs, rhs) {
        case (.entertainment, .entertainment),
             (.restTelemetry, .restTelemetry):
            return true
        case (.entertainment, _),
             (.restTelemetry, _):
            return false
        }
    }
}
