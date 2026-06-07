#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
prefix="${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}"
bin_dir="$HOME/.local/bin"
dry_run=0
remove_legacy=0

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.zsh [--dry-run] [--prefix PATH] [--legacy]

Removes the ai-litellm-fabric package directory and global command shims.

Default removal:
  - ~/.local/share/ai-litellm-fabric
  - ~/.local/bin/ai-litellm
  - ~/.local/bin/claude-litellm
  - ~/.local/bin/codex-litellm
  - ~/.local/bin/goose-litellm
  - ~/.local/bin/opencode-litellm
  - ~/.local/bin/openrouter-key-status
  - ~/.local/bin/litellm-master-key-status

With --legacy, also removes older spread-out wrapper paths:
  - ~/litellm_config.yaml
  - ~/.config/ai-litellm
  - ~/.config/claude-litellm
  - ~/.config/codex-litellm
  - ~/.config/goose-litellm
  - ~/.config/opencode-litellm

It never removes native ~/.claude or ~/.codex.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    --legacy)
      remove_legacy=1
      ;;
    --prefix)
      shift
      [[ $# -gt 0 ]] || {
        echo "--prefix requires a path" >&2
        exit 1
      }
      prefix="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

run() {
  if (( dry_run )); then
    printf 'dry-run '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

for script in ai-litellm claude-litellm codex-litellm goose-litellm opencode-litellm openrouter-key-status litellm-master-key-status; do
  run rm -f "$bin_dir/$script"
done

run rm -rf "$prefix"

if (( remove_legacy )); then
  run rm -f "$HOME/litellm_config.yaml"
  run rm -rf \
    "$HOME/.config/ai-litellm" \
    "$HOME/.config/claude-litellm" \
    "$HOME/.config/codex-litellm" \
    "$HOME/.config/goose-litellm" \
    "$HOME/.config/opencode-litellm"
fi

print -r -- "Removed ai-litellm-fabric package/shims."
(( remove_legacy )) && print -r -- "Removed legacy spread-out wrapper paths."
