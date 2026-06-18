#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
real_home="$HOME"

for file in \
  "$repo_root/scripts/install.zsh" \
  "$repo_root/scripts/uninstall.zsh" \
  "$repo_root/config/ai-litellm/lib.zsh" \
  "$repo_root/config/claude-litellm/shell.zsh" \
  "$repo_root/config/codex-litellm/shell.zsh" \
  "$repo_root"/bin/*(N); do
  zsh -n "$file"
done

python3 -m py_compile "$repo_root/scripts/verify_litellm_token_clamp.py"
python3 -m py_compile "$repo_root/scripts/verify_tool_call_fidelity.py"
python3 -m py_compile "$repo_root/config/ai_litellm_callbacks/output_clamp.py"

for file in \
  "$repo_root/config/ai-litellm/settings.json" \
  "$repo_root/config/ai-litellm/context-observations.json" \
  "$repo_root/config/ai-litellm/harnesses"/*.json(N) \
  "$repo_root/config/claude-litellm/settings.json" \
  "$repo_root/config/codex-litellm/settings.json"; do
  jq empty "$file"
done

ruby -ryaml -e '(YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))' "$repo_root/config/litellm_config.yaml"

if rg --glob '!scripts/check.zsh' -n 'sk-or-v1-|sk-proj-|sk-ant-|OPENROUTER_API_KEY=.*sk-|LITELLM_MASTER_KEY=.*sk-|BRAVE_SEARCH_API_KEY\s*=|master_key:\s*sk-|api_key:\s*sk-' "$repo_root"; then
  echo "Secret-like value found in repository" >&2
  exit 1
fi

tmp_home="$(mktemp -d)"
spaced_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home" "$spaced_home"' EXIT
LITELLM_MASTER_KEY= LITELLM_MASTER_KEYCHAIN_ACCOUNT="ai-litellm-check-no-key-$$" HOME="$tmp_home" "$repo_root/scripts/install.zsh" >/dev/null
REAL_HOME="$real_home" HOME="$tmp_home" zsh -fc '
set -e
prefix="$HOME/.local/share/ai-litellm-fabric"
test -f "$HOME/.local/share/ai-litellm-fabric/config/ai-litellm/lib.zsh"
test -f "$HOME/.local/share/ai-litellm-fabric/config/ai-litellm/context-observations.json"
test -f "$HOME/.local/share/ai-litellm-fabric/config/litellm_config.yaml"
test -f "$HOME/.local/share/ai-litellm-fabric/config/ai_litellm_callbacks/output_clamp.py"
test -x "$HOME/.local/share/ai-litellm-fabric/scripts/uninstall.zsh"
test -x "$HOME/.local/share/ai-litellm-fabric/bin/claude-litellm"
test -x "$HOME/.local/bin/claude-litellm"
"$HOME/.local/bin/ai-litellm" --help >/dev/null
! grep -R "__HOME__\\|__FABRIC_HOME__" "$prefix/config" "$prefix/docs" >/dev/null
grep -q "AI_LITELLM_FABRIC_HOME=" "$HOME/.local/bin/ai-litellm"
grep -q "exec.*bin/ai-litellm" "$HOME/.local/bin/ai-litellm"
source "$prefix/config/ai-litellm/lib.zsh"
grep -q "^LITELLM_MASTER_KEY=" "$prefix/state/ai-litellm/env"
test "$(stat -f %Lp "$prefix/state/ai-litellm/env")" = "600"
test -n "$(ai_litellm_master_key)"
test "$(ai_litellm_model_resolve openrouter/deepseek/deepseek-v4-pro)" = "DeepSeek-V4-Pro-openrouter"
test "$(ai_litellm_model_resolve deepseek/deepseek-v4-pro)" = "DeepSeek-V4-Pro-openrouter"
test "$(ai_litellm_model_backend openrouter/deepseek/deepseek-v4-pro)" = "openrouter/deepseek/deepseek-v4-pro"
ai_litellm_model_limits openrouter/moonshotai/kimi-k2.6 >/dev/null
test "$(ai_litellm_model_reasoning_allowed_efforts openrouter/deepseek/deepseek-v4-pro)" = "none minimal low medium high xhigh"
# Un-rendered placeholder guard (run-from-checkout footgun): a literal
# __FABRIC_HOME__ path must be refused; the rendered prefix path must pass.
# Non-vacuous: if the guard is missing, the positive assertion below fails.
if ai_litellm_assert_rendered_path "__FABRIC_HOME__/state/goose-litellm" "test" 2>/dev/null; then
  echo "ai_litellm_assert_rendered_path accepted an un-rendered path" >&2
  exit 1
fi
ai_litellm_assert_rendered_path "$prefix/state/goose-litellm" "test"
runtime_routes_dry="$(ai_litellm_runtime_routes_write omlx 1 MarkItDown gemma4-12b)"
[[ "$runtime_routes_dry" == *"MarkItDown-omlx -> openai/MarkItDown"* ]]
[[ "$runtime_routes_dry" != *"gemma4-12b"* ]]
# Robustness: a runtime that is reachable but whose /v1/models returns an
# UNPARSEABLE body must NOT silently wipe existing discovered routes — discovery
# failure (rc!=0) is distinct from a genuine empty model list and must skip the
# rewrite, keeping the routes. (Regression for the 2026-06-15 silent-wipe fix.)
rob_port="$(python3 -c "import socket;s=socket.socket();s.bind((\"127.0.0.1\",0));print(s.getsockname()[1]);s.close()")"
python3 -c "
import sys,http.server
class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*a): pass
  def do_GET(self):
    self.send_response(200); self.end_headers(); self.wfile.write(b\"GARBAGE NOT JSON\")
http.server.HTTPServer((\"127.0.0.1\",$rob_port),H).serve_forever()
" >/dev/null 2>&1 &
rob_mock_pid=$!
for i in $(seq 1 20); do curl -sf --max-time 1 "http://127.0.0.1:$rob_port/v1/models" >/dev/null 2>&1 && break; sleep 0.2; done
rob_settings="$HOME/rob-settings.json"
print -r -- "{\"runtimes\":{\"mock\":{\"kind\":\"openai-compatible\",\"baseUrl\":\"http://127.0.0.1:$rob_port\",\"apiBase\":\"http://127.0.0.1:$rob_port/v1\",\"discoverModels\":true,\"defaultModelInfo\":{\"max_input_tokens\":8192,\"max_output_tokens\":4096}}}}" > "$rob_settings"
rob_cfg="$HOME/rob-cfg.yaml"
print -r -- "model_list:
# BEGIN ai-litellm discovered local routes
  - model_name: Keep-mock
    litellm_params:
      model: openai/Keep
      api_base: http://127.0.0.1:9/v1
      api_key: none
    model_info:
      max_input_tokens: 8192
# END ai-litellm discovered local routes

general_settings:
  master_key: x" > "$rob_cfg"
rob_out="$(AI_LITELLM_SETTINGS="$rob_settings" AI_LITELLM_CONFIG="$rob_cfg" ai_litellm_runtime_routes_refresh 0 2>&1 || true)"
[[ "$rob_out" == *"discovery failed"* ]]
test "$(grep -c "model_name: Keep-mock" "$rob_cfg")" = "1"   # route PRESERVED, not wiped
kill "$rob_mock_pid" 2>/dev/null || true
# Robustness: a second concurrent sync must REFUSE loud (dedicated sync lock,
# deadlock-free vs the proxy-start lock) and do NO rewrite — held-lock returns
# immediately before any file is touched. (Reclaim-of-dead-holder + release are
# verified separately; not exercised here to keep the suite from running a full
# regenerating sync.)
mkdir -p "$AI_LITELLM_HOME"; mkdir "$AI_LITELLM_HOME/litellm.sync.lock"
print -r -- "$$" > "$AI_LITELLM_HOME/litellm.sync.lock/pid"   # $$ is the live test shell -> kill -0 passes
date -u "+%Y-%m-%dT%H:%M:%SZ" > "$AI_LITELLM_HOME/litellm.sync.lock/started_at"  # fresh -> age << max, no reclaim
sync_busy="$(ai_litellm_sync --no-restart 2>&1 || true)"
[[ "$sync_busy" == *"another sync is in progress"* ]]
rm -f "$AI_LITELLM_HOME/litellm.sync.lock/pid" "$AI_LITELLM_HOME/litellm.sync.lock/started_at"; rmdir "$AI_LITELLM_HOME/litellm.sync.lock"
ai_litellm_runtime_routes_write omlx 0 "Qwen3.6-Test-27B" "PlainLocal" >/dev/null
grep -A8 "model_name: Qwen3.6-Test-27B-omlx" "$AI_LITELLM_CONFIG" | grep -q "max_input_tokens: 131072"
grep -A8 "model_name: Qwen3.6-Test-27B-omlx" "$AI_LITELLM_CONFIG" | grep -q "max_output_tokens: 16384"
grep -A8 "model_name: PlainLocal-omlx" "$AI_LITELLM_CONFIG" | grep -q "max_input_tokens: 8192"
# ── --json contract: proxy status ────────────────────────────────────────────
json_check() {
  local label="$1"; shift
  local out
  out="$("$@" 2>/dev/null)" || { echo "FAIL($label): nonzero exit"; exit 1; }
  print -r -- "$out" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{try{JSON.parse(s)}catch(e){console.error(\"invalid JSON\");process.exit(1)}})" \
    || { echo "FAIL($label): invalid JSON"; exit 1; }
}
assert_json_key() {
  local label="$1" json="$2" key="$3"
  print -r -- "$json" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const o=JSON.parse(s);if(!(process.argv[1] in o)){console.error(\"missing key\");process.exit(1)}})" "$key" \
    || { echo "FAIL($label): missing key $key"; exit 1; }
}
ps_json="$("$HOME/.local/bin/ai-litellm" proxy status --json 2>/dev/null)"
json_check "proxy status --json" "$HOME/.local/bin/ai-litellm" proxy status --json
for k in config settings baseUrl health configCurrency log pid pidFile lock; do
  assert_json_key "proxy status --json" "$ps_json" "$k"
done
# default output unchanged: still human text, no leading brace
ps_text="$("$HOME/.local/bin/ai-litellm" proxy status 2>/dev/null)"
[[ "$ps_text" != \{* ]] || { echo "FAIL: default proxy status became JSON"; exit 1; }
echo "ok: proxy status --json"
# litellmParamsOverrides: a glob-matched discovered route gets extra litellm_params
# (e.g. thinking-off via extra_body) injected; non-matching routes do NOT. Tested
# via a temp settings overlay so the shipped empty {} stays behavior-preserving.
params_settings_tmp="$HOME/omlx-params-test.json"
test -n "$AI_LITELLM_SETTINGS" && test -f "$AI_LITELLM_SETTINGS"  # guard: never let jq fall back to stdin (would hang)
jq '.runtimes.omlx.litellmParamsOverrides = {"*Test-35B*": {"extra_body": {"chat_template_kwargs": {"enable_thinking": false}}}}' < "$AI_LITELLM_SETTINGS" > "$params_settings_tmp"
AI_LITELLM_SETTINGS="$params_settings_tmp" ai_litellm_runtime_routes_write omlx 0 "Qwen3.6-Test-35B" "Qwen3.6-Test-27B" >/dev/null
grep -A12 "model_name: Qwen3.6-Test-35B-omlx" "$AI_LITELLM_CONFIG" | grep -q "enable_thinking: false"
! grep -A12 "model_name: Qwen3.6-Test-27B-omlx" "$AI_LITELLM_CONFIG" | grep -q "enable_thinking"
ai_litellm_model_info_anchor_refs_ok
for harness in "${(@f)$(ai_litellm_harness_names)}"; do
  ai_litellm_harness_validate "$harness"
done
ai_litellm_model_limits GLM-5.1-openrouter >/dev/null
ai_litellm_context_gateway_clamp_policy_ok
ai_litellm_context_gateway_clamp_configured
# Output-reservation policy must agree across all descriptors + the gateway copy.
ai_litellm_context_output_reservation_aligned
# Non-vacuous: a drifted gateway copy must trip the guard (if-form avoids the zsh
# `set -e` + return-1 early exit that bare !-negation can cause).
reservation_drift_cfg="$HOME/reservation-drift.yaml"
sed 's/tokenizer_headroom: 8192/tokenizer_headroom: 8191/' "$AI_LITELLM_CONFIG" > "$reservation_drift_cfg"
if AI_LITELLM_CONFIG="$reservation_drift_cfg" ai_litellm_context_output_reservation_aligned 2>/dev/null; then
  echo "output reservation alignment guard failed to detect a drifted gateway copy" >&2
  exit 1
fi
ai_litellm_context_gateway_cost_guardrail_policy_ok
ai_litellm_context_gateway_cost_guardrail_configured
ai_litellm_context_observations_ok
ai_litellm_model_info_anchor_refs_ok
openrouter_models_fixture="$HOME/openrouter-models.json"
print -r -- "{\"data\":[{\"id\":\"deepseek/deepseek-v4-pro\",\"context_length\":1048576,\"top_provider\":{\"context_length\":1048576,\"max_completion_tokens\":384000},\"supported_parameters\":[\"reasoning\"]},{\"id\":\"moonshotai/kimi-k2.6\",\"context_length\":262144,\"top_provider\":{\"context_length\":262142,\"max_completion_tokens\":262142},\"supported_parameters\":[\"reasoning\",\"reasoning_effort\"]},{\"id\":\"z-ai/glm-5.1\",\"context_length\":202752,\"top_provider\":{\"context_length\":202752,\"max_completion_tokens\":null},\"supported_parameters\":[\"reasoning\",\"reasoning_effort\"]}]}" > "$openrouter_models_fixture"
export AI_LITELLM_OPENROUTER_MODELS_JSON="$openrouter_models_fixture"
ai_litellm_model_refresh_capabilities --check >/dev/null
ai_litellm_model_policy_audit >/dev/null
PYTHONPATH="$prefix/config" AI_LITELLM_CONFIG="$prefix/config/litellm_config.yaml" python3 - <<'"'"'PY'"'"'
from ai_litellm_callbacks.output_clamp import (
    CALLBACK_NAME,
    clamp_token_reservations,
    enforce_cost_guardrail,
    gateway_cost_guardrail_decision,
    gateway_output_cap,
)

assert CALLBACK_NAME == "ai_litellm_callbacks.output_clamp.proxy_handler_instance"
shared = {
    "max_tokens": 999999,
    "max_completion_tokens": 999999,
    "model_info": {"max_input_tokens": 262144, "max_output_tokens": 262144},
}
assert gateway_output_cap(shared) == 32000
clamp_token_reservations(shared)
assert shared["max_tokens"] == 32000
assert shared["max_completion_tokens"] == 32000

small = {
    "max_tokens": 999999,
    "model_info": {"max_input_tokens": 8192, "max_output_tokens": 4096},
}
assert gateway_output_cap(small) == 3277
clamp_token_reservations(small)
assert small["max_tokens"] == 3277

allowed = gateway_cost_guardrail_decision({"messages": [{"role": "user", "content": "short"}], "max_tokens": 8})
assert allowed["allowed"] is True
large = {"messages": [{"role": "user", "content": " ".join(f"w{i}" for i in range(200001))}], "max_tokens": 1}
blocked = gateway_cost_guardrail_decision(large)
assert blocked["allowed"] is False
try:
    enforce_cost_guardrail(large)
except Exception as exc:
    assert "cost guardrail rejected" in str(exc)
else:
    raise AssertionError("large request was not rejected by cost guardrail")
PY
ai_litellm_context_observations DeepSeek >/dev/null
matrix_opus="$(ai_litellm_context_matrix claude-litellm)"
print -r -- "$matrix_opus" | grep -q ">=211580"
test "$(ai_litellm_harness_json codex models.default)" = "gpt-5.5"
budget="$(ai_litellm_harness_output_budget claude sonnet Kimi-K2.6-openrouter)"
test "$(print -r -- "$budget" | jq -r ".effectiveInput > 0 and .reservation < .capability")" = "true"
codex_budget="$(ai_litellm_harness_output_budget codex gpt-5.4 gpt-5.4)"
test "$(print -r -- "$codex_budget" | jq -r ".effectiveInput")" = "221950"
codex_catalog_map="$(ai_litellm_codex_catalog_context_map codex)"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.4\"")" = "221950"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.4-mini\"")" = "221950"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.5\"")" = "1008384"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"Gemma4-12B-omlx\"")" = "8192"
codex_catalog="$(ai_litellm_harness_json codex paths.modelCatalog)"
mkdir -p "${codex_catalog:h}"
print -r -- "{\"models\":[{\"slug\":\"gpt-5.4\",\"context_window\":262144}]}" > "$codex_catalog"
! ai_litellm_doctor_limit_sync >/dev/null 2>&1
print -r -- "{\"models\":[{\"slug\":\"gpt-5.4\",\"context_window\":221950}]}" > "$codex_catalog"
ai_litellm_doctor_limit_sync >/dev/null
ai_litellm_render_claude_settings claude
claude_settings="$(ai_litellm_harness_json claude paths.settingsArg)"
test -f "$claude_settings"
jq empty "$claude_settings"
test "$(jq -r ".enableWorkflows == true and .skipWorkflowUsageWarning == true" "$claude_settings")" = "true"
test "$(jq -r ".permissions.defaultMode" "$claude_settings")" = "default"
test "$(stat -f %Lp "$claude_settings")" = "600"
claude_settings_proxy="$(ai_litellm_harness_json claude paths.settingsArgProxy)"
test -f "$claude_settings_proxy"
jq empty "$claude_settings_proxy"
test "$(jq -r ".enableWorkflows == true and .skipWorkflowUsageWarning == true" "$claude_settings_proxy")" = "true"
test "$(jq -r ".permissions.defaultMode" "$claude_settings_proxy")" = "default"
test "$(stat -f %Lp "$claude_settings_proxy")" = "600"
lint_root="$HOME/lint-claude"
mkdir -p "$lint_root"
print -r -- "{\"env\":{\"ANTHROPIC_BASE_URL\":\"http://127.0.0.1:1\"}}" > "$lint_root/settings.json"
! ai_litellm_claude_shared_settings_lint claude "$lint_root" 2>/dev/null
print -r -- "{\"permissions\":{\"defaultMode\":\"bypassPermissions\"},\"env\":{\"BRAVE_SEARCH_API_KEY\":\"x\"}}" > "$lint_root/settings.json"
ai_litellm_claude_shared_settings_lint claude "$lint_root" 2>/dev/null
print -r -- "{\"model\":\"~anthropic/claude-opus-latest\"}" > "$lint_root/settings.json"
lint_warning="$(ai_litellm_claude_shared_settings_lint claude "$lint_root" 2>&1)"
[[ "$lint_warning" == *"warning"* ]]
rm -rf "$lint_root"
! ai_litellm_launch_env_injector goose configure >/dev/null 2>&1
goose_blocked="$(ai_litellm_launch_env_injector goose configure 2>&1 || true)"
[[ "$goose_blocked" == *"blocked"* ]]
source "$prefix/config/claude-litellm/shell.zsh"
test "$(_claude_litellm_default_mode)" = "proxy"
test "$(_claude_litellm_direct_default_request)" = "opus"
test "$(_claude_litellm_proxy_default_request)" = "opus"
test "$(_claude_litellm_direct_model_for_request "")" = "deepseek/deepseek-v4-pro"
test "$(_claude_litellm_direct_model_for_request opus)" = "deepseek/deepseek-v4-pro"
test "$(_claude_litellm_direct_model_arg_for_request opus)" = "opus"
test "$(_claude_litellm_direct_model_arg_for_request openrouter/deepseek/deepseek-v4-pro)" = "deepseek/deepseek-v4-pro"
test "$(_claude_litellm_direct_wire_model openrouter/moonshotai/kimi-k2.6)" = "moonshotai/kimi-k2.6"
test "$(_claude_litellm_target_model_for_request "")" = "DeepSeek-V4-Pro-openrouter"
test "$(_claude_litellm_target_model_for_request openrouter/deepseek/deepseek-v4-pro)" = "DeepSeek-V4-Pro-openrouter"
test "$(_claude_litellm_resolve_model_arg openrouter/deepseek/deepseek-v4-pro)" = "DeepSeek-V4-Pro-openrouter"
(
  _claude_litellm_launch_proxy() { print -r -- "proxy:$1"; }
  _claude_litellm_launch_direct() { print -r -- "direct:$1"; }
  test "$(claude-litellm sonnet)" = "proxy:sonnet"
  test "$(claude-litellm --direct sonnet)" = "direct:sonnet"
  test "$(claude-litellm --proxy sonnet)" = "proxy:sonnet"
  test "$(claude-litellm openrouter/deepseek/deepseek-v4-pro)" = "proxy:openrouter/deepseek/deepseek-v4-pro"
  test "$(claude-litellm --direct openrouter/deepseek/deepseek-v4-pro)" = "direct:openrouter/deepseek/deepseek-v4-pro"
  # F1: an unresolvable proxy model must ERROR (non-zero, with the bad token in
  # the message) and never reach the launcher — never leak as a prompt. These
  # are non-vacuous: without the guard the stubbed launcher prints "proxy:" and
  # returns 0, so the negated tests fail.
  ! claude-litellm --proxy Qwen3.6-35B-omlx >/dev/null 2>&1
  claude-litellm --proxy Qwen3.6-35B-omlx 2>&1 | grep -q "'Qwen3.6-35B-omlx' is not a selectable proxy model"
  ! claude-litellm --proxy h35 >/dev/null 2>&1
  ! claude-litellm not-a-real-model >/dev/null 2>&1
  test "$(claude-litellm --proxy Qwen3.6-27B-omlx)" = "proxy:Qwen3.6-27B-omlx"
)
stub_dir="$HOME/claude-stub"
mkdir -p "$stub_dir"
{
  print -r -- "#!/usr/bin/env zsh"
  print -r -- "print -r -- \"base=\$ANTHROPIC_BASE_URL\""
  print -r -- "print -r -- \"auth=\${ANTHROPIC_AUTH_TOKEN:+set}\""
  print -r -- "print -r -- \"api_key_set=\${+ANTHROPIC_API_KEY}\""
  print -r -- "print -r -- \"api_key_value=\$ANTHROPIC_API_KEY\""
  print -r -- "print -r -- \"discovery=\$CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY\""
  print -r -- "print -r -- \"attribution=\$CLAUDE_CODE_ATTRIBUTION_HEADER\""
  print -r -- "print -r -- \"max_tokens_set=\${+CLAUDE_CODE_MAX_OUTPUT_TOKENS}\""
  print -r -- "print -r -- \"sonnet=\$ANTHROPIC_DEFAULT_SONNET_MODEL\""
  print -r -- "print -r -- \"sonnet_name=\$ANTHROPIC_DEFAULT_SONNET_MODEL_NAME\""
  print -r -- "print -r -- \"haiku=\$ANTHROPIC_DEFAULT_HAIKU_MODEL\""
  print -r -- "print -r -- \"haiku_name=\$ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME\""
  print -r -- "print -r -- \"subagent=\$CLAUDE_CODE_SUBAGENT_MODEL\""
  print -r -- "print -r -- \"caps=\${+ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES}:\$ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES\""
  print -r -- "print -r -- \"args=\$*\""
} > "$stub_dir/claude"
chmod +x "$stub_dir/claude"
direct_output="$(PATH="$stub_dir:$PATH" OPENROUTER_API_KEY="TEST_OPENROUTER" claude-litellm --direct sonnet -p noop)"
[[ "$direct_output" == *"base=https://openrouter.ai/api"* ]]
[[ "$direct_output" == *"auth=set"* ]]
[[ "$direct_output" == *"api_key_set=1"* ]]
[[ "$direct_output" == *"api_key_value="* ]]
[[ "$direct_output" == *"discovery=0"* ]]
[[ "$direct_output" == *"attribution=0"* ]]
[[ "$direct_output" == *"max_tokens_set=0"* ]]
[[ "$direct_output" == *"sonnet=moonshotai/kimi-k2.6"* ]]
[[ "$direct_output" == *"sonnet_name=Kimi-K2.6 (openrouter)"* ]]
[[ "$direct_output" == *"haiku=z-ai/glm-5.1"* ]]
[[ "$direct_output" == *"haiku_name=GLM-5.1 (openrouter)"* ]]
[[ "$direct_output" == *"subagent=deepseek/deepseek-v4-pro"* ]]
[[ "$direct_output" == *"caps=0:"* ]]
[[ "$direct_output" == *"--model sonnet"* ]]
[[ "$direct_output" == *"--settings $prefix/state/claude-litellm/overlay-settings.json"* ]]
test -L "$prefix/state/claude-litellm/claude-config/settings.json"
test "$(readlink "$prefix/state/claude-litellm/claude-config/settings.json")" = "$HOME/.claude/settings.json"
test -L "$prefix/state/claude-litellm/claude-config/CLAUDE.md"
test -L "$prefix/state/claude-litellm/claude-config/plugins"
test ! -e "$HOME/.claude"
direct_output_repeat="$(PATH="$stub_dir:$PATH" OPENROUTER_API_KEY="TEST_OPENROUTER" claude-litellm --direct sonnet -p noop)"
[[ "$direct_output_repeat" == *"attribution=0"* ]]
if find "$prefix/state/claude-litellm/claude-config" -name "*.isolated.bak*" | grep -q .; then
  echo "Unexpected shared-environment backups after repeated launch" >&2
  exit 1
fi
(
  mig_config="$HOME/mig-config"
  mkdir -p "$mig_config"
  print -r -- "{\"old\":true}" > "$mig_config/settings.json"
  mig_output="$(PATH="$stub_dir:$PATH" OPENROUTER_API_KEY="TEST_OPENROUTER" CLAUDE_LITELLM_CLAUDE_CONFIG="$mig_config" claude-litellm --direct sonnet -p noop 2>&1)"
  [[ "$mig_output" == *"moved isolated settings.json"* ]]
  test -L "$mig_config/settings.json"
  test "$(readlink "$mig_config/settings.json")" = "$HOME/.claude/settings.json"
  test "$(jq -r ".old" "$mig_config/settings.json.isolated.bak")" = "true"
)
(
  stale_output="$(PATH="$stub_dir:$PATH" OPENROUTER_API_KEY="TEST_OPENROUTER" CLAUDE_LITELLM_SETTINGS_ARG="$prefix/state/claude-litellm/claude-config/settings.json" claude-litellm --direct sonnet -p noop 2>&1)"
  [[ "$stale_output" == *"ignoring stale CLAUDE_LITELLM_SETTINGS_ARG"* ]]
  [[ "$stale_output" == *"--settings $prefix/state/claude-litellm/overlay-settings.json"* ]]
  test -L "$prefix/state/claude-litellm/claude-config/settings.json"
)
caps_settings="$prefix/config/claude-litellm/settings.json"
jq ".capabilities = {\"sonnet\": \"none\"}" "$caps_settings" > "$caps_settings.tmp"
mv "$caps_settings.tmp" "$caps_settings"
(
  ai_litellm_model_runtime_ready() { return 0; }
  ai_litellm_start() { return 0; }
  ai_litellm_master_key() { print -r -- "sk-test-master"; }
  proxy_output="$(PATH="$stub_dir:$PATH" claude-litellm --proxy sonnet -p noop 2>/dev/null)"
  [[ "$proxy_output" == *"--settings $prefix/state/claude-litellm/overlay-settings-proxy.json"* ]]
  [[ "$proxy_output" == *"discovery=1"* ]]
  [[ "$proxy_output" == *"attribution=0"* ]]
  [[ "$proxy_output" == *"max_tokens_set=1"* ]]
  [[ "$proxy_output" == *"sonnet=Kimi-K2.6-openrouter"* ]]
  [[ "$proxy_output" == *"sonnet_name=Kimi-K2.6 (openrouter)"* ]]
  [[ "$proxy_output" == *"haiku=Qwen3.6-27B-omlx"* ]]
  [[ "$proxy_output" == *"haiku_name=Qwen3.6-27B (omlx)"* ]]
  [[ "$proxy_output" == *"caps=1:"* ]]
  [[ "$proxy_output" == *"--model sonnet"* ]]
)
ai_litellm_model_limits Qwen3.6-27B-omlx >/dev/null
runtime_routes_dedup="$(ai_litellm_runtime_routes_write omlx 1 Qwen3.6-27B-4bit)"
[[ -z "$runtime_routes_dedup" ]]  # dedup must yield NO route for an upstream a registry entry already serves
! ai_litellm_launch_env_injector goose DeepSeek-V4-Pro-openrouter configure >/dev/null 2>&1
goose_model_blocked="$(ai_litellm_launch_env_injector goose DeepSeek-V4-Pro-openrouter configure 2>&1 || true)"
[[ "$goose_model_blocked" == *"blocked"* ]]
"$HOME/.local/bin/claude-litellm" --status >/dev/null
source "$prefix/config/codex-litellm/shell.zsh"
test "$(_codex_litellm_resolve_model openrouter/deepseek/deepseek-v4-pro)" = "gpt-5.5"
test "$(_codex_litellm_resolve_model DeepSeek-V4-Pro-openrouter)" = "gpt-5.5"
test "$(_codex_litellm_resolve_model openrouter/moonshotai/kimi-k2.6)" = "gpt-5.4"
test "$(_codex_litellm_resolve_model openai/gemma4-12b)" = "Gemma4-12B-omlx"
test "$(_codex_litellm_resolve_model Gemma4-12B-omlx)" = "Gemma4-12B-omlx"
# Pre-flight: a codex binary that cannot start (e.g. the macOS-Tahoe dyld hang)
# must make a session launch fail LOUD + fast, never hang. A hanging stub proves
# the bounded probe times out and reports actionably; an instant stub passes.
codex_stub_dir="$HOME/codex-stub"; mkdir -p "$codex_stub_dir"
{ print -r -- "#!/bin/sh"; print -r -- "exec sleep 30"; } > "$codex_stub_dir/hang-codex"; chmod +x "$codex_stub_dir/hang-codex"
preflight_out="$(AI_LITELLM_CODEX_PREFLIGHT_TIMEOUT=1 _codex_litellm_preflight "$codex_stub_dir/hang-codex" 2>&1; print -r -- rc=$?)"
[[ "$preflight_out" == *"did not start within"* ]]
[[ "$preflight_out" == *"rc=1"* ]]
{ print -r -- "#!/bin/sh"; print -r -- "echo codex-cli 0.0.0-test"; } > "$codex_stub_dir/ok-codex"; chmod +x "$codex_stub_dir/ok-codex"
AI_LITELLM_CODEX_PREFLIGHT_TIMEOUT=5 _codex_litellm_preflight "$codex_stub_dir/ok-codex" >/dev/null 2>&1
ai_litellm_render_opencode_config opencode
test "$(stat -f %Lp "$prefix/state")" = "700"
test "$(stat -f %Lp "$prefix/state/ai-litellm")" = "700"
test "$(stat -f %Lp "$prefix/state/opencode-litellm/opencode.json")" = "600"
"$HOME/.local/bin/ai-litellm" key set openrouter "PLACEHOLDER\$(touch $HOME/PWNED)END" >/dev/null 2>/dev/null
test "$(ai_litellm_env_value OPENROUTER_API_KEY)" = "PLACEHOLDER\$(touch $HOME/PWNED)END"
test -n "$(ai_litellm_env_value LITELLM_MASTER_KEY)"
test ! -e "$HOME/PWNED"
if command -v security >/dev/null 2>&1; then
  keychain_service="ai-litellm-check-openrouter-$$"
  REAL_HOME="${REAL_HOME:?}" HOME="$REAL_HOME" OPENROUTER_KEYCHAIN_SERVICE="$keychain_service" "$prefix/bin/ai-litellm" key set --keychain openrouter "PLACEHOLDER_KEYCHAIN" >/dev/null 2>/dev/null
  test "$(HOME="$REAL_HOME" security find-generic-password -s "$keychain_service" -a "$USER" -w)" = "PLACEHOLDER_KEYCHAIN"
  HOME="$REAL_HOME" security delete-generic-password -s "$keychain_service" -a "$USER" >/dev/null 2>&1
fi
"$HOME/.local/bin/ai-litellm" uninstall --dry-run >/dev/null
sleep 60 &
foreign_pid=$!
mkdir -p "$HOME/.config/ai-litellm"
print -r -- "$foreign_pid" > "$HOME/.config/ai-litellm/litellm.pid"
! ai_litellm_pid_running
ai_litellm_stop >/dev/null 2>&1 || true
kill -0 "$foreign_pid"
kill "$foreign_pid"
rmdir "$HOME/.config/ai-litellm" "$HOME/.config" 2>/dev/null || true
ai_litellm_restart() { echo "unexpected restart" >&2; return 99; }
sync_output="$(ai_litellm_sync --dry-run)"
[[ "$sync_output" == *"proxy restart skipped"* ]]
[[ "$sync_output" == *"- claude settings"* ]]
tool_dir="$HOME/toolbin"
mkdir -p "$tool_dir"
for tool in node jq ruby python3 curl rg grep sed awk shasum perl mkdir chmod stat find kill sleep rmdir; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ "$tool_path" == /* ]] && ln -sf "$tool_path" "$tool_dir/$tool"
done
old_path="$PATH"
PATH="$tool_dir:/usr/bin:/bin:/usr/sbin:/sbin"
for harness in claude codex goose opencode; do
  cli="$(ai_litellm_harness_json "$harness" command)"
  if command -v "$cli" >/dev/null 2>&1; then
    echo "Expected $cli to be absent from restricted PATH" >&2
    exit 1
  fi
  info="$(ai_litellm_harness_info "$harness")"
  [[ "$info" == *"Status:    ok"* ]]
  [[ "$info" == *"CLI:       not installed"* ]]
done
ai_litellm_doctor_harnesses >/dev/null
restricted_sync_output="$(ai_litellm_sync --dry-run)"
[[ "$restricted_sync_output" == *"codex catalog skipped"* ]]
[[ "$restricted_sync_output" == *"- codex config"* ]]
[[ "$restricted_sync_output" == *"- claude settings"* ]]
[[ "$restricted_sync_output" == *"- opencode config"* ]]
[[ "$restricted_sync_output" == *"proxy restart skipped"* ]]
PATH="$old_path"
test ! -e "$HOME/litellm_config.yaml"
test ! -e "$HOME/.config/ai-litellm"
test ! -e "$HOME/.config/claude-litellm"
test ! -e "$HOME/.config/codex-litellm"
test ! -e "$HOME/.claude"
test ! -e "$HOME/.codex"
'

spaced_prefix="$spaced_home/with space/ai-litellm-fabric"
LITELLM_MASTER_KEY= LITELLM_MASTER_KEYCHAIN_ACCOUNT="ai-litellm-check-no-key-spaced-$$" HOME="$spaced_home" "$repo_root/scripts/install.zsh" --prefix "$spaced_prefix" >/dev/null
HOME="$spaced_home" "$spaced_home/.local/bin/ai-litellm" --help >/dev/null
grep -q "'$spaced_prefix'" "$spaced_home/.local/bin/ai-litellm"
LITELLM_MASTER_KEY= LITELLM_MASTER_KEYCHAIN_ACCOUNT="ai-litellm-check-no-key-spaced-$$" HOME="$spaced_home" "$repo_root/scripts/install.zsh" --prefix "$spaced_prefix" >/dev/null
if find "$spaced_home/.local" -name "*.bak.*" | grep -q .; then
  echo "Unexpected backup files after identical reinstall" >&2
  find "$spaced_home/.local" -name "*.bak.*" >&2
  exit 1
fi
HOME="$spaced_home" "$spaced_home/.local/bin/ai-litellm" uninstall >/dev/null
test ! -e "$spaced_prefix"
if find "$spaced_home/.local/bin" -type f | grep -q .; then
  echo "Unexpected command or backup files after uninstall" >&2
  find "$spaced_home/.local/bin" >&2
  exit 1
fi
if HOME="$spaced_home" "$repo_root/scripts/uninstall.zsh" --prefix "$spaced_home/not-fabric" >/dev/null 2>&1; then
  echo "Unsafe uninstall prefix was accepted" >&2
  exit 1
fi

echo "ok"
