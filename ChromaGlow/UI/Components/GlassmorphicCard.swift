// GlassmorphicCard.swift
// ChromaGlow — Epic 2 / Story 2.1
//
// General-purpose glassmorphic container card.
// Wraps any content in an .ultraThinMaterial surface with:
//   - Gradient border (white tint on top edge, transparent at bottom)
//   - Optional warm glow halo (active when isActive = true)
//   - Spring-animated state transitions
//
// Story 2.2 will layer DragGesture modifiers directly on top of this card.

import SwiftUI

// MARK: - GlassmorphicCard

struct GlassmorphicCard<Content: View>: View {

    var isActive: Bool          // drives glow + border intensity
    var cornerRadius: CGFloat   = 20
    var glowColor: Color        = .yellow
    var glowRadius: CGFloat     = 40
    var padding: CGFloat        = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            // ── Glass surface ─────────────────────────────
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)

            // ── Border gradient ───────────────────────────
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(isActive ? 0.45 : 0.18),
                            .white.opacity(isActive ? 0.12 : 0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            // ── Content ───────────────────────────────────
            content()
                .padding(padding)
        }
        // ── Glow halo via shadow — stays within layout bounds ─────────────────
        // Using .shadow on the ZStack instead of an oversized fill rectangle:
        //   ✓ Never overflows card bounds into adjacent cards or screen edges
        //   ✓ No off-screen GPU render texture (no .blur())
        //   ✓ Composited by Core Animation at the layer level
        .shadow(
            color: isActive ? glowColor.opacity(0.55) : .clear,
            radius: glowRadius * 0.5,
            x: 0, y: 6
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: isActive)
    }
}

// MARK: - Archetype → SF Symbol

/// Maps Hue room archetype strings to SF Symbols.
/// Falls back to "lightbulb.fill" for unknown archetypes.
func archetypeIcon(for archetype: String?) -> String {
    switch archetype?.lowercased() {
    case "living_room":         return "sofa.fill"
    case "kitchen":             return "fork.knife"
    case "dining":              return "fork.knife.circle.fill"
    case "bedroom":             return "bed.double.fill"
    case "kids_bedroom":        return "teddybear.fill"
    case "bathroom":            return "shower.fill"
    case "nursery":             return "figure.and.child.holdinghands"
    case "recreation":         return "gamecontroller.fill"
    case "office":              return "desktopcomputer"
    case "gym":                 return "dumbbell.fill"
    case "hallway":             return "door.left.hand.open"
    case "toilet":              return "toilet.fill"
    case "front_door":          return "sensor.tag.radiowaves.forward.fill"
    case "garage":              return "car.fill"
    case "terrace", "garden":  return "leaf.fill"
    case "driveway":            return "road.lanes"
    case "carport":             return "car.2.fill"
    case "home":                return "house.fill"
    case "downstairs":          return "arrow.down.to.line"
    case "upstairs":            return "arrow.up.to.line"
    case "top_floor":           return "building.2.fill"
    case "attic":               return "triangle.fill"
    case "guest_room":          return "person.2.fill"
    case "staircase":           return "stairs"
    case "lounge":              return "chair.fill"
    case "man_cave":            return "popcorn.fill"
    case "computer":            return "laptopcomputer"
    case "studio":              return "music.mike"
    case "music":               return "music.note"
    case "tv":                  return "tv.fill"
    case "reading":             return "book.fill"
    case "closet":              return "tshirt.fill"
    case "storage":             return "archivebox.fill"
    case "laundry_room":        return "washer.fill"
    case "balcony":             return "sun.horizon.fill"
    case "porch":               return "house.and.flag.fill"
    case "barbecue":            return "flame.fill"
    case "pool":                return "figure.pool.swim"
    default:                    return "lightbulb.fill"
    }
}

// MARK: - Preview helper (no-op on device)

#if DEBUG
struct GlassmorphicCard_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GlassmorphicCard(isActive: true) {
                Text("Living Room")
                    .foregroundStyle(.white)
            }
            .frame(height: 140)
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
