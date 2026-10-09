# WP1 + WP2 — what changed, what was NOT verified

Nothing here was compiled or run (no Flutter SDK available). Files were syntax-checked with a Dart parser only.
First steps after extracting: `flutter pub get && flutter analyze && flutter test`.

## Delete by hand (a zip cannot delete)
- `lib/services/gemini_adapter.dart` (no longer used)

## Done
- New `lib/ai/`: typed `AiError`, retry/failover `AiRetryPolicy` (6-call cap), SSE parser, three wire formats
  (OpenAI-compatible, Gemini native, Anthropic native), `AiClient`, `ProviderDoctor`, image downscaling.
- `AiService` keeps its public API but runs on the single new code path (stream and non-stream share it).
- Gemini: key header-only, no `thinkingConfig`, `thoughtSignature` kept (new `ChatMessage.toolMeta`), unique tool-call ids.
- Never sends `tools: []`; tool-less recovery; true text deltas (chat screen no longer shows only the last chunk).
- Chat: max 5 tool loops, sequential tool execution, errors built from `AiError.kind` (no raw exception text).
- Tools: model cannot delete accounts or open onboarding; confirmation dialog for delete_day, clear_all, account switch/create.
- Logger: base64 removed, entries capped, off in release; debug dialog only in debug builds.
- Keys removed from URLs in onboarding/settings model fetches (+ `pageSize=1000`); retired model ids removed.
- Tests: `test/ai/` (fake provider server + core tests).

## Deviations from the plan
- 401/403: other providers in the fallback chain are still tried (same-provider models are skipped).
- Old settings keys are kept (no `AiSettingsRepository` migration); provider identity is still by name.
- Timeout/retry/race-mode settings are now ignored (UI controls remain until WP3).
- `ProviderDoctor` exists and is tested-by-design but is not yet wired into any screen.

## Not done
- Live provider matrix, captured real error bodies, `[verify]` items (Gemini 3 signature placeholder, OpenAI
  `max_completion_tokens`, Anthropic fields, OpenRouter metadata fields).
- Android cleartext config for LAN servers. WP3-WP8 untouched.
