# AllbertAssistWeb

Phoenix web surface for Allbert Assist.

Start the web demo:

```sh
export ALLBERT_HOME=/tmp/allbert-v005-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

The `/agent` LiveView uses the same `AllbertAssist.Runtime.submit_user_input/1`
boundary as the CLI and displays response status, signal id, and trace path
when tracing is enabled. The `/settings` LiveView uses Settings Central for
operator settings, provider profile status, skill trust settings, and editable
permission defaults. Its Security & Permissions section reads effective
Security Central status through the registered `security_status` action.
