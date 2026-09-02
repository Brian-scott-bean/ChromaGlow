# FlashSafety shared vectors

`flash_safety_vectors.json` is the equivalence oracle for the Android port of the iOS
`BeatMath.FlashSafety` luminance semantics (`DefaultFlashSafety`).

## How it was generated (2026-09-02)

1. `gen_vectors.swift` (kept here for reproducibility) contains the iOS math extracted
   VERBATIM by line range from `HueHome/Core/Audio/BeatBinding.swift`
   (file sha256 prefix `1a09de6de5af703d`): the constants block and the pure functions
   `dimmingLuminance`, `inverseDimmingLuminance`, `linearRGB`, `chromaticityLuminanceFactor`,
   `redDriveFraction`. `WireFrame.relativeLuminance`/`isSaturatedRed` and the two candidacy
   rules (`isOnsetCandidate`, `isColdOnsetCandidate`) are transcribed with the gate state passed
   as parameters (the originals read `OnsetGate` fields).
2. Run with the local toolchain: `xcrun swift gen_vectors.swift > flash_safety_vectors.json`
   (Apple Swift 6.3.3). No Xcode project is involved.
3. `luminance[]`: 21 chromaticities (Party palette, storm ambient/flash, D65, (0.3,0.3), gamut
   A/B/C primaries, effect tints) × 21 dimming steps, plus degenerate inputs (y = 0, NaN xy,
   NaN/negative/over-range brightness, the 0.901→1.0 case).
4. `onsets[]`: every ordered pair of 23 frames × 3 troughs (last frame's luminance, a low
   trough, zero) with the iOS verdict, whether the pair is a chromaticity step (> 0.02) and
   whether either side is saturated red; plus the cold-start verdict for every frame.

## What the Android test asserts

`FlashSafetyEquivalenceTest`: relative luminance, red fraction, chroma factor and saturated-red
agree to 1e-12; onset verdicts agree exactly wherever the frozen `LuminanceFrame` can express
the iOS input; for red↔red pairs without a chromaticity step the Android verdict may only be
MORE conservative (never admits what iOS holds).
