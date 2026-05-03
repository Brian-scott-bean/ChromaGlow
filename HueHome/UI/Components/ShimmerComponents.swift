// ShimmerComponents.swift
// CastChroma — Stage 2A Performance
//
// Shimmer skeleton views for instant perceived load.
// Shown instead of spinners when data is being fetched from scratch.
// When SwiftData cache is populated first, these never appear.

import SwiftUI

// MARK: - ShimmerCard

/// A glassy placeholder card that pulses while rooms load.
/// Matches the exact dimensions of RoomCard so there's zero layout shift.
struct ShimmerCard: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }

            HStack(spacing: 14) {
                // Icon placeholder
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 8) {
                    ShimmerBar(width: 120, height: 13)
                    ShimmerBar(width: 64, height: 10)
                }

                Spacer()

                // Power button placeholder
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .frame(minHeight: 88)
        .shimmer(phase: phase)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1.0
            }
        }
    }
}

// MARK: - ShimmerBar

/// A single animated shimmer bar — use for text placeholder lines.
struct ShimmerBar: View {
    let width:        CGFloat
    let height:       CGFloat
    var cornerRadius: CGFloat = 6

    @State private var phase: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.10))
            .frame(width: width, height: height)
            .shimmer(phase: phase)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.0
                }
            }
    }
}

// MARK: - Shimmer ViewModifier

private struct ShimmerModifier: ViewModifier {
    let phase: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear,             location: 0),
                            .init(color: .white.opacity(0.12), location: 0.45),
                            .init(color: .clear,             location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: geo.size.width * phase - geo.size.width * 0.5)
                }
                .clipped()
            }
    }
}

private extension View {
    func shimmer(phase: CGFloat) -> some View {
        modifier(ShimmerModifier(phase: phase))
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
