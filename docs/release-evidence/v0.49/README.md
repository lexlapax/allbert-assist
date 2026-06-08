# v0.49 Release Evidence

This directory stores durable, repo-tracked operator-visible evidence for
v0.49 validation items that are not captured by the JSON release gates.

## Files

- [workspace-media-outputs-chrome.png](workspace-media-outputs-chrome.png) -
  Chrome-controlled validation of the v0.49 M10 shared multimodal
  channel/runtime fix. The screenshot shows a typed image-generation request
  rendered as an in-chat image preview and a typed TTS request rendered as an
  in-chat audio control from `media_outputs`. It was captured against a
  disposable `ALLBERT_HOME` with `image_fake` and `voice_tts_fake` fixture
  profiles.

Release gate JSON and live provider smoke evidence remain under their printed
temporary `release_evidence/` paths and are linked from the v0.49 plan and
operator guide.
