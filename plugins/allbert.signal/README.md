# Allbert Signal Channel

Signal support is implemented through a supervised `signal-cli` JSON-RPC daemon.
The channel keeps Signal identity links keyed by ACI UUID, stamps inbound content
as `:e2ee_origin`, and replies by quoting the source message timestamp.

The deterministic release lane uses an in-process JSON-RPC stub. Live validation
is opt-in through:

```sh
mix allbert.test external-smoke -- signal
```

Required live smoke configuration is documented in `docs/operator/signal-channel.md`.
