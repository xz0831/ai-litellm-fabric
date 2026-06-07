#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
dry_run=0
prefix="${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}"
bin_dir="$HOME/.local/bin"

usage() {
  cat <<'EOF'
Usage: scripts/install.zsh [--dry-run] [--prefix PATH]

Installs ai-litellm-fabric as one package directory plus global command shims.

Package directory:
  ~/.local/share/ai-litellm-fabric

Global shims:
  ~/.local/bin/ai-litellm
  ~/.local/bin/claude-litellm
  ~/.local/bin/codex-litellm
  ~/.local/bin/goose-litellm
  ~/.local/bin/opencode-litellm
  ~/.local/bin/openrouter-key-status
  ~/.local/bin/litellm-master-key-status

It does not write ~/.claude or ~/.codex and does not replace native claude/codex.
Missing native harness commands are allowed; they are only required when the
matching *-litellm command is used.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=1
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

log() {
  print -r -- "$*"
}

run() {
  if (( dry_run )); then
    printf 'dry-run '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_if_exists() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${target}.bak.${stamp}"
  run mv "$target" "$backup"
}

install_rendered() {
  local src="$1"
  local dest="$2"
  run mkdir -p "${dest:h}"
  backup_if_exists "$dest"
  if (( dry_run )); then
    log "dry-run render ${src} -> ${dest} (__HOME__=${HOME}, __FABRIC_HOME__=${prefix})"
  else
    HOME_REPL="$HOME" FABRIC_HOME_REPL="$prefix" perl -pe \
      's#__HOME__#$ENV{HOME_REPL}#g; s#__FABRIC_HOME__#$ENV{FABRIC_HOME_REPL}#g' \
      "$src" > "$dest"
  fi
}

install_executable() {
  local src="$1"
  local dest="$2"
  run mkdir -p "${dest:h}"
  backup_if_exists "$dest"
  run cp "$src" "$dest"
  run chmod 755 "$dest"
}

install_shim() {
  local name="$1"
  local dest="$bin_dir/$name"
  run mkdir -p "$bin_dir"
  backup_if_exists "$dest"
  if (( dry_run )); then
    log "dry-run shim ${dest} -> ${prefix}/bin/${name}"
  else
    {
      print '#!/usr/bin/env zsh'
      print "export AI_LITELLM_FABRIC_HOME=${(q)prefix}"
      print 'exec "$AI_LITELLM_FABRIC_HOME/bin/'"$name"'" "$@"'
    } > "$dest"
    chmod 755 "$dest"
  fi
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || {
    echo "Missing repository file: $file_path" >&2
    exit 1
  }
}

for file in \
  "$repo_root/config/litellm_config.yaml" \
  "$repo_root/config/ai-litellm/lib.zsh" \
  "$repo_root/config/ai-litellm/settings.json" \
  "$repo_root/config/ai-litellm/harnesses/schema.json" \
  "$repo_root/config/ai-litellm/harnesses/claude.json" \
  "$repo_root/config/ai-litellm/harnesses/codex.json" \
  "$repo_root/config/ai-litellm/harnesses/goose.json" \
  "$repo_root/config/ai-litellm/harnesses/opencode.json" \
  "$repo_root/config/claude-litellm/settings.json" \
  "$repo_root/config/claude-litellm/shell.zsh" \
  "$repo_root/config/codex-litellm/settings.json" \
  "$repo_root/config/codex-litellm/shell.zsh" \
  "$repo_root/docs/AI_AGENT_LITELLM_ARCHITECTURE.md"; do
  require_file "$file"
done

for script in ai-litellm claude-litellm codex-litellm goose-litellm opencode-litellm openrouter-key-status litellm-master-key-status; do
  require_file "$repo_root/bin/$script"
done

log "Installing ai-litellm-fabric from $repo_root"
log "Package: $prefix"
log "Command shims: $bin_dir"
(( dry_run )) && log "Dry run: no files will be changed"

for dir in \
  "$prefix/bin" \
  "$prefix/config/ai-litellm/harnesses" \
  "$prefix/config/claude-litellm" \
  "$prefix/config/codex-litellm" \
  "$prefix/docs" \
  "$prefix/state/ai-litellm" \
  "$prefix/state/claude-litellm/claude-config" \
  "$prefix/state/codex-litellm/codex-home" \
  "$prefix/state/goose-litellm" \
  "$prefix/state/opencode-litellm"; do
  run mkdir -p "$dir"
done

install_rendered "$repo_root/config/litellm_config.yaml" "$prefix/config/litellm_config.yaml"
install_rendered "$repo_root/config/ai-litellm/lib.zsh" "$prefix/config/ai-litellm/lib.zsh"
install_rendered "$repo_root/config/ai-litellm/settings.json" "$prefix/config/ai-litellm/settings.json"
for descriptor in "$repo_root"/config/ai-litellm/harnesses/*.json(N); do
  install_rendered "$descriptor" "$prefix/config/ai-litellm/harnesses/${descriptor:t}"
done

install_rendered "$repo_root/config/claude-litellm/settings.json" "$prefix/config/claude-litellm/settings.json"
install_rendered "$repo_root/config/claude-litellm/shell.zsh" "$prefix/config/claude-litellm/shell.zsh"

install_rendered "$repo_root/config/codex-litellm/settings.json" "$prefix/config/codex-litellm/settings.json"
install_rendered "$repo_root/config/codex-litellm/shell.zsh" "$prefix/config/codex-litellm/shell.zsh"

install_rendered "$repo_root/docs/AI_AGENT_LITELLM_ARCHITECTURE.md" "$prefix/docs/AI_AGENT_LITELLM_ARCHITECTURE.md"

for script in ai-litellm claude-litellm codex-litellm goose-litellm opencode-litellm openrouter-key-status litellm-master-key-status; do
  install_executable "$repo_root/bin/$script" "$prefix/bin/$script"
  install_shim "$script"
done

log "Installed ai-litellm-fabric package."
log "Delete with:"
log "  $repo_root/scripts/uninstall.zsh --prefix ${(q)prefix}"
log "Next:"
log "  ai-litellm proxy doctor"
log "  ai-litellm context doctor"
