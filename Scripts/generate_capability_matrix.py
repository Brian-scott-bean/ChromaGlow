#!/usr/bin/env python3
"""
generate_capability_matrix.py — Unified Customization Engine, Slice 1-2.

Regenerates docs/ios/unified-customization-capability-matrix-2026-09-01.md
directly from the shipping catalog in StudioViewModel.swift, so the matrix
cannot drift away from the code while nobody is looking.

The catalog columns (card, control, primitive, tier, entOnly) are DERIVED and
always current. The evidence columns (runtime consumer, transport, mutation
behaviour) come from the verified tables below and must only be edited when a
new proof exists — a production consumer read in the source, a passing test, or
a hardware row. Anything unproven prints as PENDING, never as a guess.

Usage:
    python3 Scripts/generate_capability_matrix.py
        Regenerate the markdown. Refuses (non-zero) if any cited evidence no
        longer verifies against the source.

    python3 Scripts/generate_capability_matrix.py --check
        Exits non-zero if the committed doc is stale OR if any cited evidence
        no longer verifies. Safe for CI.

    python3 Scripts/generate_capability_matrix.py --refresh-citations
        The ONE command to run after the orchestrator run* loops move: it
        re-finds every `paramBox.colors["<param>"]` read inside the run*
        loops, rewrites the CITED_CONSUMERS block in THIS file in place, and
        regenerates the markdown. Line numbers are never hand-maintained.

Why the citations are verified rather than trusted
--------------------------------------------------
`file:line` citations rot the moment anyone edits the cited file, and a rotted
citation is worse than none: it reads as proof while pointing at unrelated
code. So every citation here is CHECKED — the cited line must literally contain
the consuming read `paramBox.colors["<param>"]` for that exact param, and it
must sit inside a run* loop belonging to that exact card. A mismatch fails
loudly instead of printing a lie.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "HueHome/UI/Studio/StudioViewModel.swift"
OUTPUT = ROOT / "docs/ios/unified-customization-capability-matrix-2026-09-01.md"
SELF = pathlib.Path(__file__).resolve()

# Files a citation may name, by basename → repo-relative path.
CONSUMER_SOURCES = {
    "UnifiedOrchestrator.swift": "HueHome/Core/Network/UnifiedOrchestrator.swift",
}

# The consuming read, spelled exactly. Substring matching is banned here for
# the same reason it is banned for the dead sentinels below: `colors["color"]`
# is a substring of `colors["ambient_color"]`, and the two are different rows.
def consumer_read(param_id):
    return 'paramBox.colors["%s"]' % param_id


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

# The allowlist's own proof: the test that pins ENGINE_READS to the loops.
ENGINE_READS_PROOF = ("HueHomeTests/StudioParamCatalogTests.swift",
                      "testAppDrivenParamsMatchEngineReadKeys")

# Consumers read directly in production source. GENERATED — do not hand-edit
# the line numbers; run `--refresh-citations` after touching the run* loops.
# BEGIN CITED_CONSUMERS
CITED_CONSUMERS = {
    ("strobe", "flash_color"): "UnifiedOrchestrator.swift:8035",
    ("party", "color"): "UnifiedOrchestrator.swift:8193,8293",
    ("thunderstorm", "ambient_color"): "UnifiedOrchestrator.swift:8380,8404,8438,8480",
    ("thunderstorm", "flash_color"): "UnifiedOrchestrator.swift:8424,8481",
}
# END CITED_CONSUMERS

# Dead sentinels, in card+param form. NEVER match these as substrings:
# ("ambient","color") is dead, ("thunderstorm","ambient_color") is live.
DEAD_SENTINELS = {("thunderstorm", "brightness"), ("party", "saturation"),
                  ("prism", "saturation"), ("ambient", "color")}

# Bridge-native verified parameter profiles (audit §7). Source of truth:
# HueHome/Core/EffectParameterProfiles.swift — kept in lockstep by
# EffectParameterProfilesTests, the same convention as ENGINE_READS above.
#
# KNOWN LIMITATION (recorded debt, Slice 3): this table is keyed by paramID
# ONLY, exactly mirroring the Swift `profile(effect:paramID:)`, which switches
# on paramID and ignores its `effect:` argument. So every bridge-native card
# that declares `speed` gets the same row. That is honest only while the five
# parameter shapes behave identically across firmware effects; the moment one
# effect's `speed` differs, BOTH tables must become (effect, paramID)-keyed.
#
# paramID → (consumer, transport, mutation, availability, evidence).
# `evidence` mirrors the Swift EffectParameterEvidence case and drives the
# totals split — "codeProven" cites the shipping send path, "hardwarePending"
# names the exact physical check still owed.
PROFILE_SOURCE = "HueHome/Core/EffectParameterProfiles.swift"
EFFECT_PROFILES = {
    "speed": (
        "performBridgeSend speed case (code-proven, v2-only — no legacy branch)",
        "per-light effects_v2",
        "debounced",
        "active on effects_v2 lights / unavailable on legacy-only",
        "codeProven",
    ),
    "base_color": (
        "performBridgeSend base_color case (code-proven per-light v2; grouped xy fallback preserved)",
        "per-light effects_v2 / grouped xy fallback",
        "debounced",
        "active on effects_v2 lights / approximation on legacy (hardware-pending: fallback vs running effect)",
        "codeProven",
    ),
    "warmth": (
        "performBridgeSend warmth case (code-proven per-light v2 mirek; grouped fallback preserved)",
        "per-light effects_v2 / grouped mirek fallback",
        "debounced",
        "active on effects_v2 lights with readable mirek range / approximation on legacy (hardware-pending)",
        "codeProven",
    ),
    "brightness": (
        "performBridgeSend brightness case (grouped light-state write, not an effect parameter)",
        "grouped Room REST",
        "debounced",
        "active send (hardware-pending: visible scaling during an active firmware effect)",
        "hardwarePending",
    ),
    "transition": (
        "shapes dynamics.duration of subsequent sends — sends nothing itself",
        "local",
        "nextWrite",
        "active as a modifier of later writes",
        "codeProven",
    ),
}


# ── Citation verification ────────────────────────────────────────────
def _loop_functions(text):
    """[(name, first_line, last_line)] for every `func run…(` in the file."""
    lines = text.splitlines()
    starts = []
    for i, line in enumerate(lines, start=1):
        m = re.search(r"\bfunc (run[A-Za-z0-9_]*)\s*\(", line)
        if m:
            starts.append((m.group(1), i))
    spans = []
    for idx, (name, first) in enumerate(starts):
        last = starts[idx + 1][1] - 1 if idx + 1 < len(starts) else len(lines)
        spans.append((name, first, last))
    return spans


def _card_loop_prefix(card_id):
    return "run" + card_id[:1].upper() + card_id[1:]


def _read_consumer_source(basename):
    rel = CONSUMER_SOURCES.get(basename)
    if rel is None:
        return None, None
    path = ROOT / rel
    if not path.exists():
        return None, None
    return path, path.read_text()


def discover_citations():
    """Re-find every consuming read inside the run* loops, per (card, param).

    Returns (citations, warnings). A read is attributed to the card whose loop
    prefix owns the enclosing function, so `runPartyREST` can only ever produce
    a `party` citation.
    """
    citations, warnings = {}, []
    for basename in sorted(CONSUMER_SOURCES):
        path, text = _read_consumer_source(basename)
        if text is None:
            warnings.append("cannot read consumer source %s" % basename)
            continue
        lines = text.splitlines()
        spans = _loop_functions(text)
        prefixes = sorted(
            ((_card_loop_prefix(card), card) for card in ENGINE_READS),
            key=lambda pc: -len(pc[0]),
        )
        for fn_name, first, last in spans:
            card = next((c for p, c in prefixes if fn_name.startswith(p)), None)
            if card is None:
                continue
            for lineno in range(first, last + 1):
                for m in re.finditer(r'paramBox\.colors\["([A-Za-z0-9_]+)"\]',
                                     lines[lineno - 1]):
                    param = m.group(1)
                    if param not in ENGINE_READS.get(card, set()):
                        warnings.append(
                            "%s:%d reads %s.%s, which is NOT in the ENGINE_READS "
                            "allowlist — the allowlist is drifting from the loops"
                            % (basename, lineno, card, param))
                    citations.setdefault((card, param), (basename, []))[1].append(lineno)
    return ({k: "%s:%s" % (v[0], ",".join(str(n) for n in sorted(set(v[1]))))
             for k, v in citations.items()}, warnings)


def verify_citations():
    """[] when every cited line still contains its consuming read."""
    errors = []
    for (card, param), citation in sorted(CITED_CONSUMERS.items()):
        if ":" not in citation:
            errors.append("%s.%s: citation %r is not file:line" % (card, param, citation))
            continue
        basename, linespec = citation.rsplit(":", 1)
        path, text = _read_consumer_source(basename)
        if text is None:
            errors.append("%s.%s: cited file %s is unknown or missing"
                          % (card, param, basename))
            continue
        lines = text.splitlines()
        spans = _loop_functions(text)
        prefix = _card_loop_prefix(card)
        needle = consumer_read(param)
        for token in linespec.split(","):
            if not token.strip().isdigit():
                errors.append("%s.%s: bad line number %r" % (card, param, token))
                continue
            lineno = int(token)
            if lineno < 1 or lineno > len(lines):
                errors.append("%s.%s: cited line %s is past the end of %s (%d lines)"
                              % (card, param, lineno, basename, len(lines)))
                continue
            if needle not in lines[lineno - 1]:
                errors.append(
                    "%s.%s: %s:%d no longer contains %s — it reads:\n      %s"
                    % (card, param, basename, lineno, needle,
                       lines[lineno - 1].strip()))
                continue
            owner = next((n for n, f, l in spans if f <= lineno <= l), None)
            if owner is None or not owner.startswith(prefix):
                errors.append(
                    "%s.%s: %s:%d is inside %s, which is not a %s loop — the "
                    "citation would credit the wrong card"
                    % (card, param, basename, lineno, owner or "no run* loop", card))
    return errors


def verify_allowlist_sources():
    """Cheap existence proofs for the two allowlists' cited sources."""
    errors = []
    rel, symbol = ENGINE_READS_PROOF
    path = ROOT / rel
    if not path.exists():
        errors.append("ENGINE_READS cites %s, which does not exist" % rel)
    elif symbol not in path.read_text():
        errors.append("ENGINE_READS cites %s::%s, which is gone from the file"
                      % (rel, symbol))

    path = ROOT / PROFILE_SOURCE
    if not path.exists():
        errors.append("EFFECT_PROFILES cites %s, which does not exist" % PROFILE_SOURCE)
    else:
        text = path.read_text()
        if "enum EffectParameterProfiles" not in text:
            errors.append("EffectParameterProfiles is gone from %s" % PROFILE_SOURCE)
        for param in sorted(EFFECT_PROFILES):
            if 'case "%s":' % param not in text:
                errors.append("EFFECT_PROFILES row %r has no `case \"%s\":` in %s — "
                              "the Swift table no longer declares it"
                              % (param, param, PROFILE_SOURCE))
    return errors


def refresh_citations():
    """Rewrite the CITED_CONSUMERS block in this file from the live source."""
    citations, warnings = discover_citations()
    body = ["CITED_CONSUMERS = {"]
    for (card, param), citation in sorted(citations.items(),
                                          key=lambda kv: kv[1].split(":")[-1]):
        body.append('    ("%s", "%s"): "%s",' % (card, param, citation))
    body.append("}")
    rendered = "\n".join(body)

    text = SELF.read_text()
    # Anchored at column 0 so the marker literals inside THIS function can
    # never be mistaken for the block they delimit.
    pattern = re.compile(r"(^# BEGIN CITED_CONSUMERS\n).*?(\n^# END CITED_CONSUMERS$)",
                         re.DOTALL | re.MULTILINE)
    if not pattern.search(text):
        print("REFRESH FAILED: the CITED_CONSUMERS markers are gone from %s"
              % SELF.name, file=sys.stderr)
        return None, warnings
    updated = pattern.sub(lambda m: m.group(1) + rendered + m.group(2), text, count=1)
    if updated != text:
        SELF.write_text(updated)
        print("refreshed CITED_CONSUMERS in %s" % SELF.relative_to(ROOT))
    else:
        print("CITED_CONSUMERS already current")
    for line in warnings:
        print("WARNING: %s" % line, file=sys.stderr)
    return citations, warnings


# ── Catalog ──────────────────────────────────────────────────────────
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
            return prof[:4]
        return ("PENDING — needs effect profile", "firmware effects_v2 / legacy",
                "PENDING (reapply vs live unproven)", "PENDING")

    return ("PENDING", "PENDING", "PENDING", "PENDING")


def classify(card, param):
    """'codeProven' | 'hardwarePending' | 'pending' | 'dead' for the totals."""
    key = (card["id"], param["id"])
    if key in DEAD_SENTINELS:
        return "dead"
    if card["strategy"] == "appDriven":
        return ("codeProven" if param["id"] in ENGINE_READS.get(card["id"], set())
                else "pending")
    if card["strategy"] == "bridgeNative":
        prof = EFFECT_PROFILES.get(param["id"])
        return prof[4] if prof else "pending"
    return "pending"


def render(cards):
    effects = [c for c in cards if c["strategy"] == "bridgeNative"]
    live = [c for c in cards if c["strategy"] == "appDriven"]
    total = sum(len(c["params"]) for c in cards)
    counts = {"codeProven": 0, "hardwarePending": 0, "pending": 0, "dead": 0}
    for c in cards:
        for p in c["params"]:
            counts[classify(c, p)] += 1
    unproven = counts["pending"] + counts["dead"]

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
    A("\nEvery `file:line` citation below is machine-verified on every run: the cited line must\n"
      "still contain the consuming read for that exact parameter, inside a run loop belonging to\n"
      "that exact card. `--check` fails if a citation has rotted; `--refresh-citations` re-finds\n"
      "the line numbers after the loops move.\n")
    A(f"\n## Totals\n")
    A(f"\n| | Cards | Controls |\n| --- | ---: | ---: |\n")
    A(f"| Effects (bridge-native) | {len(effects)} | {sum(len(c['params']) for c in effects)} |\n")
    A(f"| Live (app-driven) | {len(live)} | {sum(len(c['params']) for c in live)} |\n")
    A(f"| **Total** | **{len(cards)}** | **{total}** |\n")
    A("\n### Evidence split\n")
    A("\n| Evidence | Controls | Meaning |\n| --- | ---: | --- |\n")
    A(f"| Code-proven | {counts['codeProven']} / {total} | A live-path consumer read in the "
      "shipping source (app-driven), or a `codeProven` profile citing the send path "
      "(bridge-native). |\n")
    A(f"| Hardware-pending | {counts['hardwarePending']} / {total} | The send path exists and is "
      "cited, but the physical behaviour is NOT validated. Audit §7 still owes this evidence. |\n")
    dead_note = (f" Includes {counts['dead']} dead sentinel(s), which render hidden."
                 if counts["dead"] else "")
    A(f"| Pending / unknown | {unproven} / {total} | No proof at all — the control must not "
      f"render as active (audit §29).{dead_note} |\n")
    A("\n**Hardware evidence is still owed.** Audit §7 counts a row as proven only when a physical "
      "bridge has shown the behaviour. The hardware-pending rows above name the exact check still "
      "outstanding (see `pendingHardwareChecks` in `HueHome/Core/EffectParameterProfiles.swift` and "
      "the §V-B on-device checklist); until those checks run, those controls must not be described "
      "or rendered as fully live. Code-proven means the write provably leaves the app — not that "
      "anyone has watched a light obey it.\n")

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
    A("- Per-effect differences in a bridge-native parameter: the profile table is keyed by "
      "paramID only, mirroring `profile(effect:paramID:)`, which ignores its `effect:` argument. "
      "Recorded Slice 3 debt.\n")
    A("- Hardware validation: nothing in this matrix has been validated on a physical bridge in "
      "this slice.\n")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the committed doc is stale or a citation has rotted")
    ap.add_argument("--refresh-citations", action="store_true",
                    help="re-find the cited line numbers from the run* loops, rewrite the "
                         "CITED_CONSUMERS block in this script, and regenerate the markdown")
    args = ap.parse_args()

    if args.refresh_citations:
        citations, _ = refresh_citations()
        if citations is None:
            return 1
        globals()["CITED_CONSUMERS"] = citations

    errors = verify_citations() + verify_allowlist_sources()
    if errors:
        print("capability matrix: cited evidence no longer verifies —", file=sys.stderr)
        for e in errors:
            print("  - %s" % e, file=sys.stderr)
        print("  Fix the code, or re-find the line numbers with:\n"
              "    python3 Scripts/generate_capability_matrix.py --refresh-citations",
              file=sys.stderr)
        return 1

    rendered = render(parse_catalog(SOURCE.read_text()))

    if args.check:
        if not OUTPUT.exists():
            print(f"MISSING: {OUTPUT}", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != rendered:
            print(f"STALE: {OUTPUT} — re-run {pathlib.Path(__file__).name}", file=sys.stderr)
            return 1
        print("capability matrix: %d citation(s) verified, doc up to date"
              % len(CITED_CONSUMERS))
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(CITED_CONSUMERS)} citation(s) verified)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
