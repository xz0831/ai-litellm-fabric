#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"

for file in \
  "$repo_root/scripts/install.zsh" \
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
trap 'rm -rf "$tmp_home"' EXIT
HOME="$tmp_home" "$repo_root/scripts/install.zsh" >/dev/null
HOME="$tmp_home" zsh -fc '
source "$HOME/.config/ai-litellm/lib.zsh"
ai_litellm_model_limits GLM-5.1 >/dev/null
ai_litellm_harness_output_budget claude haiku GLM-5.1 >/dev/null
test -x "$HOME/.local/bin/claude-litellm"
test ! -e "$HOME/.claude"
test ! -e "$HOME/.codex"
'

echo "ok"
