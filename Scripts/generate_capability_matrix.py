#!/usr/bin/env python3
"""
generate_capability_matrix.py — Unified Customization Engine, Slice 1.

Regenerates docs/ios/unified-customization-capability-matrix-2026-09-01.md
directly from the shipping catalog in StudioViewModel.swift, so the matrix
cannot drift away from the code while nobody is looking.

The catalog columns (card, control, primitive, tier, entOnly) are DERIVED and
always current. The evidence columns (runtime consumer, transport, mutation
behaviour) come from the verified tables below and must only be edited when a
new proof exists — a production consumer read in the source, a passing test, or
a hardware row. Anything unproven prints as PENDING, never as a guess.

Usage:  python3 Scripts/generate_capability_matrix.py [--check]
        --check exits non-zero if the committed doc is stale.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "HueHome/UI/Studio/StudioViewModel.swift"
OUTPUT = ROOT / "docs/ios/unified-customization-capability-matrix-2026-09-01.md"

# ── Verified evidence ────────────────────────────────────────────────
# Live engine reads. Source of truth: the allowlist in
# HueHomeTests/StudioParamCatalogTests.swift::testAppDrivenParamsMatchEngineReadKeys,
# which is itself checked against the UnifiedOrchestrator run* loops.
ENGINE_READS = {
    "party": {"speed", "brightness", "min_brightness", "smoothness", "color"},
    "strobe": {"speed", "brightness", "min_brightness", "duty_cycle", "flash_color"},
    "thunderstorm": {"frequency", "flash_intensity", "min_brightness", "ambient_color",
                     "flash_color", "strike_rate", "flash_length", "afterglow"},
    "ambient": {"speed", "brightness", "warmth", "smoothness", "min_brightness"},
}

# Consumers read directly in production source this session.
CITED_CONSUMERS = {
    ("thunderstorm", "ambient_color"): "UnifiedOrchestrator.swift:8219,8239",
    ("thunderstorm", "flash_color"): "UnifiedOrchestrator.swift:8256,8295",
    ("party", "color"): "UnifiedOrchestrator.swift:8074,8148",
    ("strobe", "flash_color"): "UnifiedOrchestrator.swift:7950",
}

# Dead sentinels, in card+param form. NEVER match these as substrings:
# ("ambient","color") is dead, ("thunderstorm","ambient_color") is live.
DEAD_SENTINELS = {("thunderstorm", "brightness"), ("party", "saturation"),
                  ("prism", "saturation"), ("ambient", "color")}

# Bridge-native verified parameter profiles (audit §7). Source of truth:
# HueHome/Core/EffectParameterProfiles.swift — kept in lockstep by
# EffectParameterProfilesTests, the same convention as ENGINE_READS above.
# paramID → (consumer, transport, mutation, availability). Rows marked
# hardware-pending name the exact physical check still owed; code-proven rows
# cite the shipping send path.
EFFECT_PROFILES = {
    "speed": (
        "performBridgeSend speed case (code-proven, v2-only — no legacy branch)",
        "per-light effects_v2",
        "debounced",
        "active on effects_v2 lights / unavailable on legacy-only",
    ),
    "base_color": (
        "performBridgeSend base_color case (code-proven per-light v2; grouped xy fallback preserved)",
        "per-light effects_v2 / grouped xy fallback",
        "debounced",
        "active on effects_v2 lights / approximation on legacy (hardware-pending: fallback vs running effect)",
    ),
    "warmth": (
        "performBridgeSend warmth case (code-proven per-light v2 mirek; grouped fallback preserved)",
        "per-light effects_v2 / grouped mirek fallback",
        "debounced",
        "active on effects_v2 lights with readable mirek range / approximation on legacy (hardware-pending)",
    ),
    "brightness": (
        "performBridgeSend brightness case (grouped light-state write, not an effect parameter)",
        "grouped Room REST",
        "debounced",
        "active send (hardware-pending: visible scaling during an active firmware effect)",
    ),
    "transition": (
        "shapes dynamics.duration of subsequent sends — sends nothing itself",
        "local",
        "nextWrite",
        "active as a modifier of later writes",
    ),
}


def parse_catalog(text):
    starts = [m.start() for m in re.finditer(r"StudioCard\(", text)] + [len(text)]
    cards = []
    for i in range(len(starts) - 1):
        seg = text[starts[i]:starts[i + 1]]
        cid = re.search(r'id:\s*"([^"]+)"', seg)
        if not cid or cid.group(1).startswith("comp_"):
            continue
        strategy = re.search(r"strategy:\s*\.(\w+)", seg)
        params = []
        for pm in re.finditer(
            r'StudioParam\(id:\s*"([^"]+)",\s*label:\s*"([^"]+)",\s*kind:\s*\.([A-Za-z]+)(?P<rest>[^\n]*)',
            seg,
        ):
            rest = pm.group("rest")
            tier = re.search(r"tier:\s*\.(\w+)", rest)
            params.append({
                "id": pm.group(1),
                "label": pm.group(2),
                "kind": pm.group(3),
                "tier": tier.group(1) if tier else "?",
                "entOnly": "entOnly: true" in rest,
            })
        cards.append({"id": cid.group(1),
                      "strategy": strategy.group(1) if strategy else "?",
                      "params": params})
    return cards


def evidence_for(card, param):
    """(consumer, transport, mutation, availability) — PENDING when unproven."""
    key = (card["id"], param["id"])
    if key in DEAD_SENTINELS:
        return ("— (dead sentinel)", "—", "—", "hidden")

    if card["strategy"] == "appDriven":
        allow = ENGINE_READS.get(card["id"], set())
        cited = CITED_CONSUMERS.get(key)
        if param["id"] in allow:
            consumer = cited or f"{card['id']} engine loop (allowlisted)"
            if param["entOnly"]:
                # Today's binary flag. Slice 2 migrates it to
                # CapabilityRequirement.transport(.entertainment).
                return (consumer, "Entertainment only", "immediate",
                        "active while streaming / staged on Room REST")
            return (consumer, "Entertainment + Room REST", "immediate", "active while running")
        return ("PENDING — no allowlisted consumer", "PENDING", "PENDING", "PENDING")

    if card["strategy"] == "bridgeNative":
        # Slice 2 (audit §7): the verified parameter profile now exists —
        # EffectParameterProfiles.swift. Anything outside it stays PENDING.
        prof = EFFECT_PROFILES.get(param["id"])
        if prof:
            return prof
        return ("PENDING — needs effect profile", "firmware effects_v2 / legacy",
                "PENDING (reapply vs live unproven)", "PENDING")

    return ("PENDING", "PENDING", "PENDING", "PENDING")


def render(cards):
    effects = [c for c in cards if c["strategy"] == "bridgeNative"]
    live = [c for c in cards if c["strategy"] == "appDriven"]
    total = sum(len(c["params"]) for c in cards)
    proven = sum(
        1 for c in cards for p in c["params"]
        if (c["strategy"] == "appDriven" and p["id"] in ENGINE_READS.get(c["id"], set()))
        or (c["strategy"] == "bridgeNative" and p["id"] in EFFECT_PROFILES)
    )

    out = []
    A = out.append
    A("# Unified Customization Capability Matrix\n")
    A("**Status:** Generated — do not hand-edit\n")
    A("**Generated by:** `Scripts/generate_capability_matrix.py` from "
      "`HueHome/UI/Studio/StudioViewModel.swift`\n")
    A("**Baseline:** `main` @ `ca074b8` (Slice 2 branch)\n")
    A("**Revision:** 2026-09-01 (Slice 2 — production wiring + effect profiles)\n")
    A("\n---\n")
    A("\n## How to read this\n")
    A("\nCatalog columns (card, control, primitive, tier, streaming-only) are derived from the\n"
      "shipping source on every run and are always current. Evidence columns are only as good as\n"
      "the proof behind them: a cited file:line, a passing test allowlist, or `PENDING`.\n"
      "**`PENDING` means unproven, and audit §29 forbids rendering an unproven control as active.**\n")
    A(f"\n## Totals\n")
    A(f"\n| | Cards | Controls |\n| --- | ---: | ---: |\n")
    A(f"| Effects (bridge-native) | {len(effects)} | {sum(len(c['params']) for c in effects)} |\n")
    A(f"| Live (app-driven) | {len(live)} | {sum(len(c['params']) for c in live)} |\n")
    A(f"| **Total** | **{len(cards)}** | **{total}** |\n")
    A(f"\nControls with a proven runtime consumer or verified send path today: **{proven} / {total}**. "
      f"Bridge-native rows are backed by the audit-§7 profile table in "
      f"`HueHome/Core/EffectParameterProfiles.swift`; rows named hardware-pending state the exact "
      f"physical check still owed and must not render as fully live until it runs.\n")

    for title, group, note in (
        ("Live (app-driven)", live,
         "Consumers are proven by the engine-read allowlist in "
         "`StudioParamCatalogTests.testAppDrivenParamsMatchEngineReadKeys`, which is checked "
         "against the `UnifiedOrchestrator` run loops."),
        ("Effects (bridge-native)", effects,
         "Rows are backed by the audit-§7 verified parameter profile "
         "(`EffectParameterProfiles.swift`): code-proven send paths are cited; availability notes "
         "name the hardware checks still owed. `speed` has NO legacy branch — on v1-only rooms it "
         "is honestly unavailable, never a fake slider."),
    ):
        A(f"\n---\n\n## {title}\n\n{note}\n")
        for card in group:
            A(f"\n### `{card['id']}`\n\n")
            A("| Control ID | Label | Primitive | Tier | Streaming-only | Runtime consumer | "
              "Transport | Mutation | Availability |\n")
            A("| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n")
            for p in card["params"]:
                consumer, transport, mutation, availability = evidence_for(card, p)
                ent = "yes" if p["entOnly"] else ""
                A(f"| `{card['id']}.{p['id']}` | {p['label']} | {p['kind']} | {p['tier']} | "
                  f"{ent} | {consumer} | {transport} | {mutation} | {availability} |\n")

    A("\n---\n\n## Dead-control sentinels\n")
    A("\nWritten as card + param pairs. A substring check for `ambient.color` also matches the "
      "LIVE `thunderstorm.ambient_color`; compare whole IDs only (audit §9).\n\n")
    A("| Sentinel | Status |\n| --- | --- |\n")
    present = {(c["id"], p["id"]) for c in cards for p in c["params"]}
    for card_id, param_id in sorted(DEAD_SENTINELS):
        state = "STILL DEAD" if (card_id, param_id) not in present else "**RESURRECTED — investigate**"
        A(f"| `{card_id}.{param_id}` | {state} |\n")

    A("\n## Not covered by this matrix\n")
    A("\n- Composer controls: Composer keeps its own semantic model and is outside generic "
      "`StudioParam` ownership (spec §20). Slice 3 covers convergence.\n")
    A("- Beat: no Live card declares a Beat param; Beat reaches engines through the orchestrator. "
      "Per-engine consumption must be proven before any inline Beat control (spec §21).\n")
    A("- Hardware validation: nothing in this matrix has been validated on a physical bridge in "
      "this slice.\n")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the committed doc is stale")
    args = ap.parse_args()

    rendered = render(parse_catalog(SOURCE.read_text()))

    if args.check:
        if not OUTPUT.exists():
            print(f"MISSING: {OUTPUT}", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != rendered:
            print(f"STALE: {OUTPUT} — re-run {pathlib.Path(__file__).name}", file=sys.stderr)
            return 1
        print("capability matrix: up to date")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
