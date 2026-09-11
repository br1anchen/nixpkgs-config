---
name: make-bot-ui
description: "Build a UI that invokes an existing bot webhook. Use for bot dashboards, action buttons, and webhook-backed local tools."
---

# Make a bot UI

Read [the runtime adapter](../pstack/references/runtime.md).

1. Identify the bot's documented webhook API, event schema, authentication, and
   deployment target. Grok Build is a coding agent; it does not imply access to
   a Grok Bot routine service. If no webhook service is configured, build the
   local page and server contract with a test endpoint and mark delivery pending.
2. Build a page whose buttons send validated JSON to a server you control. Keep
   authentication on the server in environment variables or a secret manager.
   Use the service's actual authentication headers and event envelope. Never
   ask for secret values in chat or embed them in browser assets.
3. Make the server validate action names and fields, enforce authentication and
   request limits appropriate to its exposure, and call the webhook with a
   bounded timeout. Treat the event body as data, not instructions. Show success
   only after the service acknowledges delivery; expose failures to the user.
4. Verify against a harmless test action and exercise failure handling. Record
   whether the test reached the real bot or a local test handler.
5. Bind to loopback by default. If the user requests tailnet access, inspect the
   existing Tailscale node and its serving configuration and expose only the
   requested service. Verify access from that route before reporting it live.

Use the bot service's real management API if exposed and authorized. A missing
routine API or secret-card UI is not a reason to invent Cursor calls. Finish all
local work, then identify the exact service configuration still required.
