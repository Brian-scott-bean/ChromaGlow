# Telemetry Primer

## What Telemetry Means

Telemetry is app health and behavior data sent from the app to a backend/tool so the team can understand whether the app is working.

For ChromaGlow, telemetry should answer questions like:

- Are users able to discover their bridge?
- Are users able to pair successfully?
- Are local network permissions being denied?
- Are SSE connections dropping?
- Are scene activations failing?
- Is Android failing more often on specific device models?
- Are crashes happening after a release?

## What Telemetry Is Not

Telemetry should not be surveillance.

Avoid collecting:

- Hue credentials.
- Raw bridge tokens.
- Audio data.
- Room names by default.
- Light names by default.
- Precise local IP addresses unless intentionally reviewed.
- Personal user content unless the feature explicitly needs it.

## Recommended Starting Events

### App Health

- app_start
- app_start_failed
- app_version_seen
- cold_launch_duration_bucket

### Pairing

- bridge_scan_started
- bridge_scan_mdns_found
- bridge_scan_nupnp_fallback_used
- bridge_pairing_started
- bridge_pairing_success
- bridge_pairing_failed

### Connectivity

- local_network_permission_denied
- bridge_unreachable
- certificate_trust_failed
- sse_connected
- sse_disconnected
- sse_reconnected

### Control

- room_toggle_success
- room_toggle_failed
- light_toggle_success
- light_toggle_failed
- scene_activate_success
- scene_activate_failed

### Later

- widget_action_success
- widget_action_failed
- wear_sync_success
- wear_sync_failed
- entertainment_session_start_failed
- studio_apply_failed

## Recommended Rule

Start with event names and counts. Avoid rich payloads until privacy rules are documented.

## Provider Decision Later

Do not choose a telemetry provider until the team agrees on:

- What events are acceptable.
- What data is never acceptable.
- Whether users need an opt-out.
- How long event data should be retained.
- Who can access the dashboard.
