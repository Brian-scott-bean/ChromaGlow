// Composer2Random.swift
// ChromaGlow — Composer 2 lab (experimental, isolated under Core/Composer2).
//
// Deterministic randomness for the Composer 2 engine: a tiny SplitMix64
// generator, stateless hashing (never `Hasher`, which is per-process
// randomized), and cubic value noise. Everything here is a pure function of
// its inputs — nothing reads a clock or the system random source, which is
// what lets the same seed reproduce the same light sequence.

import Foundation

// MARK: - Math helpers

enum Composer2Math {
    @inline(__always) static func clamp01(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return Swift.min(1, Swift.max(0, v))
    }

    @inline(__always) static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v.isNaN { return lo }
        return Swift.min(hi, Swift.max(lo, v))
    }

    /// Fractional part in 0..<1 for any finite input (negative inputs wrap).
    @inline(__always) static func frac(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        let f = v - floor(v)
        return f < 0 ? f + 1 : (f >= 1 ? 0 : f)
    }

    @inline(__always) static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    @inline(__always) static func smoothstep(_ t: Double) -> Double {
        let x = clamp01(t)
        return x * x * (3 - 2 * x)
    }

    /// `Int(floor(v))` that never traps: non-finite → 0, magnitude capped at 1e12.
    static func safeFloorInt(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        let c = Swift.min(1e12, Swift.max(-1e12, floor(v)))
        return Int(c)
    }

    /// A (lo, hi) pair with lo ≤ hi, NaN treated as 0.
    static func orderedRange(_ a: Double, _ b: Double) -> (lo: Double, hi: Double) {
        let x = a.isFinite ? a : 0
        let y = b.isFinite ? b : 0
        return x <= y ? (x, y) : (y, x)
    }

    static func orderedRange(_ a: Int, _ b: Int) -> (lo: Int, hi: Int) {
        a <= b ? (a, b) : (b, a)
    }
}

// MARK: - Seeded generator

/// SplitMix64. Any seed — including 0 — yields a non-degenerate stream, which
/// is why xorshift (locked at zero by a zero seed) is not used here.
struct Composer2Rng: RandomNumberGenerator, Equatable {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        return lo + (hi - lo) * nextUnit()
    }

    /// Bounded via an unsigned span — never `Int(Double)`.
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return lo }
        let span = UInt64(hi - lo) &+ 1
        return lo + Int(next() % span)
    }
}

// MARK: - Stateless hashing

enum Composer2Hash {
    private static let golden: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// SplitMix finalizer over `a` and `b` — stateless, order-sensitive.
    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a ^ ((b &* golden) &+ 0x632B_E59B_D9B4_E019)
        z = z &+ golden
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func seed(_ parts: UInt64...) -> UInt64 {
        parts.reduce(0x1234_5678_9ABC_DEF1) { mix($0, $1) }
    }

    /// Folds the sixteen UUID bytes — process-independent, unlike `hashValue`.
    static func seed(from id: UUID) -> UInt64 {
        let u = id.uuid
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                     u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        for i in 0..<8 {
            hi = (hi << 8) | UInt64(bytes[i])
            lo = (lo << 8) | UInt64(bytes[i + 8])
        }
        return mix(hi, lo)
    }

    /// Stateless uniform value in [0, 1) for a (seed, a, b, salt) tuple.
    static func unit(_ seed: UInt64, _ a: Int, _ b: Int = 0, salt: UInt64 = 0) -> Double {
        let ha = UInt64(bitPattern: Int64(a))
        let hb = UInt64(bitPattern: Int64(b))
        let h = mix(mix(mix(seed, ha), hb), salt)
        return Double(h >> 11) * 0x1.0p-53
    }
}

// MARK: - Value noise

/// Cubic-smoothed value noise. Output stays in 0…1, is continuous in its
/// inputs, and is a pure function of (input, seed).
enum Composer2Noise {
    private static let limit: Double = 1e9

    private static func lattice(_ v: Double) -> (index: Int, t: Double) {
        guard v.isFinite else { return (0, 0.5) }
        let c = Swift.min(limit, Swift.max(-limit, v))
        let f = floor(c)
        return (Int(f), c - f)
    }

    static func value1D(_ x: Double, seed: UInt64) -> Double {
        let (i, t) = lattice(x)
        let a = Composer2Hash.unit(seed, i, 0, salt: 0x1D)
        let b = Composer2Hash.unit(seed, i &+ 1, 0, salt: 0x1D)
        return Composer2Math.lerp(a, b, Composer2Math.smoothstep(t))
    }

    static func value2D(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let (ix, tx) = lattice(x)
        let (iy, ty) = lattice(y)
        let sx = Composer2Math.smoothstep(tx)
        let sy = Composer2Math.smoothstep(ty)
        let a = Composer2Hash.unit(seed, ix, iy, salt: 0x2D)
        let b = Composer2Hash.unit(seed, ix &+ 1, iy, salt: 0x2D)
        let c = Composer2Hash.unit(seed, ix, iy &+ 1, salt: 0x2D)
        let d = Composer2Hash.unit(seed, ix &+ 1, iy &+ 1, salt: 0x2D)
        let top = Composer2Math.lerp(a, b, sx)
        let bottom = Composer2Math.lerp(c, d, sx)
        return Composer2Math.lerp(top, bottom, sy)
    }

    /// Fractal sum (gain 0.5, lacunarity 2), renormalized to 0…1.
    static func fbm2D(_ x: Double, _ y: Double, seed: UInt64, octaves: Int = 2) -> Double {
        let n = Swift.max(1, Swift.min(6, octaves))
        var amplitude = 1.0
        var frequency = 1.0
        var total = 0.0
        var norm = 0.0
        for octave in 0..<n {
            let s = Composer2Hash.mix(seed, UInt64(octave))
            total += amplitude * value2D(x * frequency, y * frequency, seed: s)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return norm > 0 ? Composer2Math.clamp01(total / norm) : 0.5
    }
}
