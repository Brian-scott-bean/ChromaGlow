// FailableDecodable.swift
// ChromaGlow — audit M-13/L-27.
//
// Lossy element decoding: wrapping array elements in FailableDecodable makes
// one malformed element decode to nil instead of failing the WHOLE array —
// the difference between losing a single corrupt composition and reseeding
// the user's entire library, or between skipping one malformed bridge
// resource and rendering zero rooms.

import Foundation

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}
