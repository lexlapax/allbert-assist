# Allbert Slack Channel

Shipped v0.52 Slack channel plugin.

The v0.52 implementation uses raw `Req` for Slack Web API calls and a direct
`websockex` Socket Mode client for live inbound sessions. Deterministic release
tests still use stubs and fixtures, but configured operator runs and the
external-smoke lanes exercise the real transport boundaries with Settings
Central secret refs, channel allowlists, identity mapping, inbound trust, and
cross-channel thread mapping.
