# Allbert Matrix Channel Plugin

Shipped source-tree plugin for Allbert's Matrix channel adapter.

v0.53 compiles this plugin only through explicit project configuration. The
manifest is discovery metadata, not a runtime code-loading instruction.

M6 supports unencrypted Matrix rooms only: text `m.room.message` events from
`/sync`, bearer-auth outbound `m.room.message` sends, and Matrix thread metadata
with rich-reply fallback.
