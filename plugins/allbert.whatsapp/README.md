# Allbert WhatsApp Channel Plugin

Shipped source-tree plugin for Allbert's WhatsApp Cloud API channel adapter.

v0.53 compiles this plugin only through explicit project configuration. The
manifest is discovery metadata, not a runtime code-loading instruction.

M7 supports the Cloud API text and in-session interactive button paths. Inbound
messages arrive through the signed public webhook substrate from M4; outbound
messages use bearer-auth `/{phone_number_id}/messages` calls through Settings
Central secret refs. Conversation continuity uses reply-chain metadata with a
quote TTL fallback to flat replies when the provider quote window expires.
