# ai-litellm-fabric

Portable harness fabric for local AI agent CLIs.

This repository manages the wrapper layer around local agent CLIs:

- `ai-litellm`: shared proxy lifecycle, routing, context/reasoning doctors
- `claude-litellm`: Claude Code on non-Anthropic models — LiteLLM proxy by default (OpenRouter + local oMLX routes), with an OpenRouter Anthropic-compatible direct mode (`--direct`)
- `codex-litellm`: Codex CLI through the shared LiteLLM proxy
- `goose-litellm`: goose through the shared LiteLLM proxy
- `opencode-litellm`: OpenCode through the shared LiteLLM proxy

It shares the user-scope environment with native harnesses while keeping
session state isolated per variant:

- shared by reference (symlinks from the fabric Claude config dir into
  `~/.claude`): `settings.json`, `settings.local.json`, `plugins`, `skills`,
  `keybindings.json`, `CLAUDE.md`
- isolated per variant: transcripts (`projects/`), auto-memory, prompt
  history, todos, credentials, `.claude.json` identity — cross-backend
  `--resume`/`--continue` and memory pollution stay structurally impossible
- backend routing travels only as per-invocation process env plus a per-mode
  `--settings` overlay; launch refuses to start if the shared settings env
  block carries backend-routing keys (`ANTHROPIC_BASE_URL`,
  `ANTHROPIC_AUTH_TOKEN`/`API_KEY`, model/tier pin envs, `OPENROUTER_*`,
  `LITELLM_*`) — benign keys like telemetry/OTel settings are not blocked
- the fabric itself still never writes into `~/.claude`; writes through the
  shared links are performed by Claude Code itself (permission decisions,
  plugin state) exactly as a native session would
- no writes to `~/.codex` (codex keeps a fully isolated `CODEX_HOME`;
  see the session-boundary decision log in the architecture guide)
- no replacement of `claude`, `codex`, `goose`, or `opencode`
- no API keys in git

The installed wrapper layer is one package directory plus thin global command
shims:

- package: `~/.local/share/ai-litellm-fabric`
- commands: `~/.local/bin/*-litellm`

Downloading the repository does not automatically create global commands. Run
`./scripts/install.zsh` once after clone/download; the installer creates shims
that work from any directory.

## What Git Owns

Tracked source:

- `bin/*`: wrapper commands
- `config/litellm_config.yaml`: LiteLLM model registry and model token limits
- `config/ai-litellm/lib.zsh`: shared library
- `config/ai-litellm/settings.json`: shared proxy/runtime settings
- `config/ai-litellm/harnesses/*.json`: harness descriptors
- `config/claude-litellm/*`: Claude direct/proxy adapter settings/helper
- `config/codex-litellm/*`: Codex LiteLLM adapter settings/helper
- `docs/AI_AGENT_LITELLM_ARCHITECTURE.md`: maintainer architecture guide
- `docs/DESIGN_RATIONALE.md`: why every non-obvious decision is the way it is
  (rationale, rejected alternatives, standing counter-arguments, honest unknowns)
- `docs/APPLYING_MODELS_TO_HARNESSES.md`: practitioner playbook — given a model
  (cloud/OpenRouter or local/oMLX), how to apply it to Claude Code / Codex / goose /
  opencode with the context & token budgeting right, with worked examples
  (DeepSeek-V4-Pro, Kimi-K2.6, GLM-5.1, local Qwen3.6)
- `scripts/install.zsh`: installer for another Mac
- `scripts/uninstall.zsh`: package/shim remover

Installed package/runtime state:

- `~/.local/share/ai-litellm-fabric/config`: rendered wrapper config
- `~/.local/share/ai-litellm-fabric/bin`: installed wrapper executables
- `~/.local/share/ai-litellm-fabric/docs`: installed maintainer guide
- `~/.local/share/ai-litellm-fabric/scripts`: installed package tools, including
  uninstall
- `~/.local/share/ai-litellm-fabric/state`: proxy logs, pid files, config
  hashes, harness sessions, sqlite databases, caches, generated configs, local
  private env file
- `~/.local/bin`: global shims that point into the package

Still not tracked or installed:

- provider API keys
- local model weights, including oMLX models under `~/.omlx/models`

## Install

Prerequisites on the target Mac:

- zsh, node, ruby, jq, curl, python3, perl, rg
- `litellm`
- `~/.local/bin` on `PATH`

Harness CLIs are optional. Install native `claude` only if using
`claude-litellm`, native `codex` only if using `codex-litellm`, and
`goose`/`opencode` only if using those harnesses. A Claude-only machine can
install the package without Codex.

Preview:

```zsh
./scripts/install.zsh --dry-run
```

Install:

```zsh
./scripts/install.zsh
```

The installer preflights shared dependencies, writes only the LiteLLM wrapper
layer, and creates a local LiteLLM master key if one is not already available:

- `~/.local/share/ai-litellm-fabric/config`
- `~/.local/share/ai-litellm-fabric/bin`
- `~/.local/share/ai-litellm-fabric/docs`
- `~/.local/share/ai-litellm-fabric/scripts`
- `~/.local/share/ai-litellm-fabric/state`
- `~/.local/bin/ai-litellm`
- `~/.local/bin/claude-litellm`
- `~/.local/bin/codex-litellm`
- `~/.local/bin/goose-litellm`
- `~/.local/bin/opencode-litellm`
- `~/.local/bin/openrouter-key-status`
- `~/.local/bin/litellm-master-key-status`

It creates isolated runtime directories but leaves native app directories alone.
It does not write `~/.claude`, `~/.codex`, or `~/litellm_config.yaml`; the
Claude shared-environment symlinks are created inside the fabric state dir and
only point at `~/.claude`.

Uninstall the package/shims:

```zsh
ai-litellm uninstall
```

The installed fallback is also self-contained:

```zsh
~/.local/share/ai-litellm-fabric/scripts/uninstall.zsh
```

If migrating from an older spread-out install, preview legacy cleanup first:

```zsh
./scripts/uninstall.zsh --legacy --dry-run
```

## Secrets

Store keys outside git. On macOS, prefer Keychain storage so provider keys do
not live in the package directory:

```zsh
ai-litellm key set --keychain openrouter
ai-litellm key status
```

You can also set arbitrary provider env keys:

```zsh
ai-litellm key set --keychain OPENAI_API_KEY
ai-litellm key set --keychain anthropic
```

Omit the value and enter it at the hidden prompt. Passing a secret as a command
argument can leave it in shell history or process inspection output.

For throwaway or non-macOS installs, the package also supports a private env
file, which is removed with `ai-litellm uninstall`:

```zsh
ai-litellm key set --env-file openrouter
```

For additional providers referenced as `os.environ/NAME` in
`config/litellm_config.yaml`, the default Keychain service is the lowercase
dash form of the variable name. Example: `OPENAI_API_KEY` uses service
`openai-api-key`.

## First Run

```zsh
ai-litellm key set --keychain openrouter
ai-litellm key status
ai-litellm sync
ai-litellm context doctor
ai-litellm reasoning doctor
ai-litellm proxy doctor
```

`ai-litellm sync` regenerates derived config and restarts the shared proxy by
default, which can interrupt active LiteLLM-backed sessions. Use
`ai-litellm sync --dry-run` to inspect actions first, or `--no-restart` to
regenerate without bouncing the proxy.

Supported harnesses are optional on each machine. `sync`, `doctor`, and
metadata commands must skip missing native CLIs cleanly; only launching that
specific harness requires its native command. `sync` also renders the per-mode
Claude `--settings` overlays (`overlay-settings.json` and
`overlay-settings-proxy.json`; both downgrade `permissions.defaultMode` so a
native `bypassPermissions` never reaches non-Anthropic models on either lane)
and maintains the shared-environment symlinks.

OpenRouter backend names can be used directly where a model is accepted. The
wrapper resolves them back to the configured `model_name` without duplicating
routes in git:

```zsh
ai-litellm model limits openrouter/deepseek/deepseek-v4-pro
ai-litellm model info openrouter/deepseek/deepseek-v4-pro
```

For Codex, a raw provider slug is resolved to a Codex-safe facade such as
`gpt-5.5` when that backend is shared by multiple routes. The same provider
slug can be used in place of the model argument in the harness smoke tests
below.

Then test one harness. Claude Code defaults to the LiteLLM proxy path:
tier aliases map to the curated non-Anthropic routes (the haiku tier is a
fully local oMLX model, so the haiku smoke test below is free), and the
proxy is auto-started on demand.

```zsh
claude-litellm haiku -p 'Reply with exactly OK' --no-session-persistence --tools ''
codex-litellm exec --skip-git-repo-check --sandbox read-only 'Reply with exactly OK'
```

Harness smoke tests against OpenRouter-backed tiers make real provider
requests and may be billable.

Use `--direct` for the thin OpenRouter Anthropic-compatible path (no local
proxy; OpenRouter's own model-id vocabulary; `ANTHROPIC_API_KEY` is blanked
and the OpenRouter key travels as `ANTHROPIC_AUTH_TOKEN`). Local models
cannot ride this lane — there is no LiteLLM in the path:

```zsh
claude-litellm --direct sonnet -p 'Reply with exactly OK' --no-session-persistence --tools ''
claude-litellm Gemma4-12B-omlx -p 'Reply with exactly LOCAL_OK' --no-session-persistence --tools ''
```

## Local Models

The repository tracks local runtime wiring, not model weights. OpenRouter routes
are curated recommendations, but local oMLX models are machine-specific.

`Gemma4-12B-omlx` remains a sample/recommended route. When oMLX is running,
`ai-litellm sync` also reads `http://127.0.0.1:8000/v1/models` and generates
routes for the models this computer actually serves, such as:

```zsh
ai-litellm runtime status omlx
ai-litellm sync
ai-litellm model list | grep -- '-omlx'
```

Generated local routes are named `<ModelId>-<runtime>` (suffix auto-derived
from the runtime name, lowercase — e.g. `Qwen3.6-27B-4bit-omlx`; an `ollama`
runtime would yield `-ollama`) and point at the exact runtime model id
advertised by oMLX. A discovered model is skipped when a registry entry
already serves the same backend. The actual oMLX installation and files under
`~/.omlx/models` remain machine-local.

## Token Budget Policy

Model capability and request reservation are separate concepts.

- Capability lives in `config/litellm_config.yaml` under `x-limits` and
  `model_info`.
- Harness-specific reservation lives in the harness descriptor when needed.

Some proxy-backed harnesses need explicit output reservation handling because
they send or infer per-request `max_tokens` values:

- Claude Code proxy fallback: `CLAUDE_CODE_MAX_OUTPUT_TOKENS`
- Codex LiteLLM: generated catalog `context_window` for OpenRouter-backed
  slugs is reduced to the safe input budget because Codex does not expose a
  reliable Responses output cap
- goose: `GOOSE_MAX_TOKENS`
- OpenCode: `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` for the custom
  OpenAI-compatible provider ceiling

For shared-window providers, the effective input budget is:

```text
effective_input = max_input_tokens - output_reservation - tokenizer_headroom
```

Other token-limit issues can still happen, but the failure mode differs:

- Codex LiteLLM: generated model catalog/config can drift from `x-limits`.
- LiteLLM proxy: `enable_pre_call_checks` enforces configured input limits, not
  every provider-specific reserved-output accounting rule.

To re-check gateway-side output clamping against the installed LiteLLM version:

```zsh
./scripts/verify_litellm_token_clamp.py
```

Run this after every LiteLLM upgrade: the clamp findings are
version-specific, and the doctor only checks configuration presence, not
behavior.

Current local result with LiteLLM 1.81.14: plain config does not override a
larger client `max_tokens`; `litellm_settings.modify_params: true` clamps
`max_tokens` but not `max_completion_tokens`; a custom
`async_pre_call_deployment_hook` clamps both before the mock provider receives
the request. The production proxy enables this hook and also rejects prompts
above the configured estimated-token guardrail before provider dispatch.

Use the doctors as the contract:

```zsh
ai-litellm model limits
ai-litellm context matrix
ai-litellm context observations
ai-litellm context doctor
ai-litellm proxy doctor
```

## Maintenance Boundary

When adding or changing models:

1. Update `config/litellm_config.yaml`.
2. Keep one `x-limits` anchor per underlying backend model.
3. Update harness aliases/descriptors only when the user-facing slot changes.
4. Run `ai-litellm sync`.
5. Run the doctor commands.

Do not encode native Codex/Claude product context claims in this wrapper project.
Native surfaces must be diagnosed separately from LiteLLM surfaces.
