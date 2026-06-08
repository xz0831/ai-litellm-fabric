# ai-litellm-fabric

Portable LiteLLM-backed harness fabric for local AI agent CLIs.

This repository manages only the LiteLLM wrapper layer:

- `ai-litellm`: shared proxy lifecycle, routing, context/reasoning doctors
- `claude-litellm`: Claude Code through the shared LiteLLM proxy
- `codex-litellm`: Codex CLI through the shared LiteLLM proxy
- `goose-litellm`: goose through the shared LiteLLM proxy
- `opencode-litellm`: OpenCode through the shared LiteLLM proxy

It intentionally does not manage native Claude Code or native Codex state:

- no writes to `~/.claude`
- no writes to `~/.codex`
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
- `config/claude-litellm/*`: Claude LiteLLM adapter settings/helper
- `config/codex-litellm/*`: Codex LiteLLM adapter settings/helper
- `docs/AI_AGENT_LITELLM_ARCHITECTURE.md`: maintainer architecture guide
- `scripts/install.zsh`: installer for another Mac
- `scripts/uninstall.zsh`: package/shim remover

Installed package/runtime state:

- `~/.local/share/ai-litellm-fabric/config`: rendered wrapper config
- `~/.local/share/ai-litellm-fabric/bin`: installed wrapper executables
- `~/.local/share/ai-litellm-fabric/docs`: installed maintainer guide
- `~/.local/share/ai-litellm-fabric/state`: proxy logs, pid files, config
  hashes, harness sessions, sqlite databases, caches, generated configs
- `~/.local/bin`: global shims that point into the package

Still not tracked or installed:

- provider API keys

## Install

Prerequisites on the target Mac:

- zsh, node, ruby, jq, curl
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

The installer writes only the LiteLLM wrapper layer:

- `~/.local/share/ai-litellm-fabric/config`
- `~/.local/share/ai-litellm-fabric/bin`
- `~/.local/share/ai-litellm-fabric/docs`
- `~/.local/share/ai-litellm-fabric/state`
- `~/.local/bin/ai-litellm`
- `~/.local/bin/claude-litellm`
- `~/.local/bin/codex-litellm`
- `~/.local/bin/goose-litellm`
- `~/.local/bin/opencode-litellm`
- `~/.local/bin/openrouter-key-status`
- `~/.local/bin/litellm-master-key-status`

It creates isolated runtime directories but leaves native app directories alone.
It does not write `~/.claude`, `~/.codex`, or `~/litellm_config.yaml`.

Uninstall the package/shims:

```zsh
./scripts/uninstall.zsh
```

If migrating from an older spread-out install, preview legacy cleanup first:

```zsh
./scripts/uninstall.zsh --legacy --dry-run
```

## Secrets

Store keys outside git. Recommended macOS Keychain entries:

```zsh
security add-generic-password -U -s openrouter-api-key -a "$USER" -w '...'
security add-generic-password -U -s litellm-master-key -a "$USER" -w '...'
```

For additional providers referenced as `os.environ/NAME` in
`config/litellm_config.yaml`, the default Keychain service is the lowercase
dash form of the variable name. Example: `OPENAI_API_KEY` uses service
`openai-api-key`.

## First Run

```zsh
ai-litellm proxy doctor
ai-litellm context doctor
ai-litellm reasoning doctor
ai-litellm sync
```

`ai-litellm sync` regenerates derived config and restarts the shared proxy by
default, which can interrupt active LiteLLM-backed sessions. Use
`ai-litellm sync --dry-run` to inspect actions first, or `--no-restart` to
regenerate without bouncing the proxy.

Supported harnesses are optional on each machine. `sync`, `doctor`, and
metadata commands must skip missing native CLIs cleanly; only launching that
specific harness requires its native command. `sync` also ensures the isolated
Claude Code settings file exists without touching `~/.claude`.

Then test one harness:

```zsh
claude-litellm haiku -p 'Reply with exactly OK' --no-session-persistence --tools ''
codex-litellm gpt-5.4 exec --skip-git-repo-check --sandbox read-only 'Reply with exactly OK'
```

Those harness smoke tests make real provider requests and may be billable.

## Token Budget Policy

Model capability and request reservation are separate concepts.

- Capability lives in `config/litellm_config.yaml` under `x-limits` and
  `model_info`.
- Harness-specific reservation lives in the harness descriptor when needed.

Some harnesses need explicit output reservation handling because they send or
infer per-request `max_tokens` values:

- Claude Code: `CLAUDE_CODE_MAX_OUTPUT_TOKENS`
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

Current local result with LiteLLM 1.81.14: plain config does not override a
larger client `max_tokens`; `litellm_settings.modify_params: true` clamps
`max_tokens` but not `max_completion_tokens`; a custom
`async_pre_call_deployment_hook` clamps both before the mock provider receives
the request. The production proxy does not enable this hook yet.

Use the doctors as the contract:

```zsh
ai-litellm model limits
ai-litellm context matrix
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
