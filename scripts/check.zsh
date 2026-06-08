#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"

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

for file in \
  "$repo_root/config/ai-litellm/settings.json" \
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
HOME="$tmp_home" "$repo_root/scripts/install.zsh" >/dev/null
HOME="$tmp_home" zsh -fc '
prefix="$HOME/.local/share/ai-litellm-fabric"
test -f "$HOME/.local/share/ai-litellm-fabric/config/ai-litellm/lib.zsh"
test -f "$HOME/.local/share/ai-litellm-fabric/config/litellm_config.yaml"
test -x "$HOME/.local/share/ai-litellm-fabric/bin/claude-litellm"
test -x "$HOME/.local/bin/claude-litellm"
"$HOME/.local/bin/ai-litellm" --help >/dev/null
! grep -R "__HOME__\\|__FABRIC_HOME__" "$prefix/config" "$prefix/docs" >/dev/null
grep -q "AI_LITELLM_FABRIC_HOME=" "$HOME/.local/bin/ai-litellm"
grep -q "exec.*bin/ai-litellm" "$HOME/.local/bin/ai-litellm"
source "$prefix/config/ai-litellm/lib.zsh"
for harness in "${(@f)$(ai_litellm_harness_names)}"; do
  ai_litellm_harness_validate "$harness"
done
ai_litellm_model_limits GLM-5.1 >/dev/null
budget="$(ai_litellm_harness_output_budget claude sonnet Kimi-K2.6)"
test "$(print -r -- "$budget" | jq -r ".effectiveInput > 0 and .reservation < .capability")" = "true"
codex_budget="$(ai_litellm_harness_output_budget codex gpt-5.4 gpt-5.4)"
test "$(print -r -- "$codex_budget" | jq -r ".effectiveInput")" = "221952"
codex_catalog_map="$(ai_litellm_codex_catalog_context_map codex)"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.4\"")" = "221952"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.4-mini\"")" = "221952"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"gpt-5.5\"")" = "1008384"
test "$(print -r -- "$codex_catalog_map" | jq -r ".\"local-omlx-gemma4-12b\"")" = "8192"
codex_catalog="$(ai_litellm_harness_json codex paths.modelCatalog)"
mkdir -p "${codex_catalog:h}"
print -r -- "{\"models\":[{\"slug\":\"gpt-5.4\",\"context_window\":262144}]}" > "$codex_catalog"
! ai_litellm_doctor_limit_sync >/dev/null 2>&1
print -r -- "{\"models\":[{\"slug\":\"gpt-5.4\",\"context_window\":221952}]}" > "$codex_catalog"
ai_litellm_doctor_limit_sync >/dev/null
ai_litellm_render_claude_settings claude
claude_settings="$(ai_litellm_harness_json claude paths.settingsArg)"
test -f "$claude_settings"
jq empty "$claude_settings"
test "$(stat -f %Lp "$claude_settings")" = "600"
"$HOME/.local/bin/claude-litellm" --status >/dev/null
ai_litellm_render_opencode_config opencode
test "$(stat -f %Lp "$prefix/state")" = "700"
test "$(stat -f %Lp "$prefix/state/ai-litellm")" = "700"
test "$(stat -f %Lp "$prefix/state/opencode-litellm/opencode.json")" = "600"
print -r -- "OPENROUTER_API_KEY=PLACEHOLDER\$(touch $HOME/PWNED)END" > "$prefix/state/ai-litellm/env"
test "$(ai_litellm_env_value OPENROUTER_API_KEY)" = "PLACEHOLDER\$(touch $HOME/PWNED)END"
test ! -e "$HOME/PWNED"
sleep 60 &
foreign_pid=$!
mkdir -p "$HOME/.config/ai-litellm"
print -r -- "$foreign_pid" > "$HOME/.config/ai-litellm/litellm.pid"
! ai_litellm_pid_running
ai_litellm_stop >/dev/null 2>&1
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
HOME="$spaced_home" "$repo_root/scripts/install.zsh" --prefix "$spaced_prefix" >/dev/null
HOME="$spaced_home" "$spaced_home/.local/bin/ai-litellm" --help >/dev/null
grep -q "'$spaced_prefix'" "$spaced_home/.local/bin/ai-litellm"
HOME="$spaced_home" "$repo_root/scripts/install.zsh" --prefix "$spaced_prefix" >/dev/null
if find "$spaced_home/.local" -name "*.bak.*" | grep -q .; then
  echo "Unexpected backup files after identical reinstall" >&2
  find "$spaced_home/.local" -name "*.bak.*" >&2
  exit 1
fi
HOME="$spaced_home" "$repo_root/scripts/uninstall.zsh" --prefix "$spaced_prefix" >/dev/null
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
