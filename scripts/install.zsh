#!/usr/bin/env zsh

set -euo pipefail

repo_root="${0:A:h:h}"
dry_run=0
prefix="${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}"
bin_dir="$HOME/.local/bin"

usage() {
  cat <<'EOF'
Usage: scripts/install.zsh [--dry-run] [--prefix PATH] [--skip-preflight]

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

The installer checks shared wrapper dependencies, but not optional native harness
CLIs. It also creates a local LiteLLM master key if one is not already available.
EOF
}

skip_preflight=0

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=1
      ;;
    --skip-preflight)
      skip_preflight=1
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

preflight() {
  local -a required missing
  # Tools the install/render/checks ACTUALLY invoke. litellm is intentionally not
  # here: it is a RUNTIME dependency (the proxy) that install and check.zsh never
  # call — it is hard-checked at proxy start and by `ai-litellm doctor`. Requiring
  # it to lay down files would wrongly block a files-first setup (and reds the CI
  # lint job, which has no reason to install the heavy litellm[proxy] tree).
  required=(zsh node ruby jq curl python3 perl rg)
  missing=()

  local cmd
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # litellm: runtime-only — note, never fatal (doctor/start enforce it at use time).
  command -v litellm >/dev/null 2>&1 || \
    echo "note: litellm not found — needed to start the proxy (python3 -m pip install 'litellm[proxy]'); install and checks proceed without it." >&2

  (( ${#missing[@]} == 0 )) && return 0

  echo "Missing shared ai-litellm-fabric dependencies: ${missing[*]}" >&2
  echo "Install the missing commands before using the package." >&2
  echo "Typical macOS packages: brew install node jq ripgrep" >&2
  if (( dry_run )); then
    echo "Dry run continues after preflight warning." >&2
    return 0
  fi
  exit 1
}

backup_if_exists() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S).$$"
  backup="${target}.bak.${stamp}"
  run mv "$target" "$backup"
}

install_rendered() {
  local src="$1"
  local dest="$2"
  run mkdir -p "${dest:h}"
  if (( dry_run )); then
    log "dry-run render ${src} -> ${dest} (__HOME__=${HOME}, __FABRIC_HOME__=${prefix})"
  else
    local tmp
    tmp="${dest}.tmp.$$"
    HOME_REPL="$HOME" FABRIC_HOME_REPL="$prefix" perl -pe \
      's#__HOME__#$ENV{HOME_REPL}#g; s#__FABRIC_HOME__#$ENV{FABRIC_HOME_REPL}#g' \
      "$src" > "$tmp"
    if [[ -e "$dest" || -L "$dest" ]]; then
      if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
      fi
      backup_if_exists "$dest"
    fi
    mv "$tmp" "$dest"
  fi
}

install_executable() {
  local src="$1"
  local dest="$2"
  run mkdir -p "${dest:h}"
  if (( ! dry_run )) && [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    chmod 755 "$dest"
    return 0
  fi
  backup_if_exists "$dest"
  run cp "$src" "$dest"
  run chmod 755 "$dest"
}

install_shim() {
  local name="$1"
  local dest="$bin_dir/$name"
  run mkdir -p "$bin_dir"
  if (( dry_run )); then
    log "dry-run shim ${dest} -> ${prefix}/bin/${name}"
  else
    local tmp
    tmp="${dest}.tmp.$$"
    {
      print -r -- '#!/usr/bin/env zsh'
      print -r -- "export AI_LITELLM_FABRIC_HOME=${(qq)prefix}"
      print -r -- 'exec "$AI_LITELLM_FABRIC_HOME/bin/'"$name"'" "$@"'
    } > "$tmp"
    if [[ -e "$dest" || -L "$dest" ]]; then
      if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        chmod 755 "$dest"
        return 0
      fi
      backup_if_exists "$dest"
    fi
    mv "$tmp" "$dest"
    chmod 755 "$dest"
  fi
}

env_file_has_value() {
  local file_path="$1"
  local key="$2"
  [[ -f "$file_path" ]] || return 1
  node -e '
const fs = require("fs");
const [file, wanted] = process.argv.slice(1);
for (let line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
  line = line.trim();
  if (!line || line.startsWith("#")) continue;
  if (line.startsWith("export ")) line = line.slice("export ".length).trimStart();
  const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
  if (!match || match[1] !== wanted) continue;
  if (match[2].length > 0) process.exit(0);
}
process.exit(1);
' "$file_path" "$key"
}

env_file_set_value() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  if (( dry_run )); then
    log "dry-run set ${key} in ${file_path}"
    return 0
  fi

  mkdir -p "${file_path:h}"
  node -e '
const fs = require("fs");
const [file, key, value] = process.argv.slice(1);
if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`invalid env key: ${key}`);
if (/[\r\n]/.test(value)) throw new Error(`env value for ${key} contains a newline`);
let lines = [];
try {
  lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
} catch (_) {}
let replaced = false;
const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const pattern = new RegExp(`^(\\s*(?:export\\s+)?)${escaped}=.*$`);
lines = lines.map((line) => {
  const match = line.match(pattern);
  if (!match) return line;
  replaced = true;
  return `${match[1] || ""}${key}=${value}`;
});
if (!replaced) lines.push(`${key}=${value}`);
const tmp = `${file}.tmp.${process.pid}`;
fs.writeFileSync(tmp, lines.join("\n") + "\n", {mode: 0o600});
fs.renameSync(tmp, file);
' "$file_path" "$key" "$value"
  chmod 600 "$file_path"
}

keychain_has_value() {
  local service="$1"
  local account="$2"
  [[ -n "$service" && -n "$account" ]] || return 1
  command -v security >/dev/null 2>&1 || return 1
  security find-generic-password -s "$service" -a "$account" -w >/dev/null 2>&1
}

ensure_litellm_master_key() {
  [[ -n "${LITELLM_MASTER_KEY:-}" ]] && {
    log "LiteLLM master key: current environment"
    return 0
  }

  local env_file="$prefix/state/ai-litellm/env"
  if (( dry_run )); then
    log "dry-run ensure LITELLM_MASTER_KEY in $env_file when environment/Keychain do not provide one"
    return 0
  fi

  if env_file_has_value "$env_file" LITELLM_MASTER_KEY; then
    log "LiteLLM master key: existing package env file"
    return 0
  fi

  local service account
  service="${LITELLM_MASTER_KEYCHAIN_SERVICE:-litellm-master-key}"
  account="${LITELLM_MASTER_KEYCHAIN_ACCOUNT:-${USER:-}}"
  if keychain_has_value "$service" "$account"; then
    log "LiteLLM master key: macOS Keychain"
    return 0
  fi

  local generated
  generated="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  env_file_set_value "$env_file" LITELLM_MASTER_KEY "$generated"
  log "LiteLLM master key: generated in $env_file"
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
  "$repo_root/config/ai_litellm_callbacks/__init__.py" \
  "$repo_root/config/ai_litellm_callbacks/output_clamp.py" \
  "$repo_root/config/ai-litellm/context-observations.json" \
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
  "$repo_root/docs/AI_AGENT_LITELLM_ARCHITECTURE.md" \
  "$repo_root/scripts/uninstall.zsh"; do
  require_file "$file"
done

for script in ai-litellm claude-litellm codex-litellm goose-litellm opencode-litellm openrouter-key-status litellm-master-key-status fabric; do
  require_file "$repo_root/bin/$script"
done

(( skip_preflight )) || preflight

log "Installing ai-litellm-fabric from $repo_root"
log "Package: $prefix"
log "Command shims: $bin_dir"
(( dry_run )) && log "Dry run: no files will be changed"

for dir in \
  "$prefix/bin" \
  "$prefix/config/ai_litellm_callbacks" \
  "$prefix/config/ai-litellm/harnesses" \
  "$prefix/config/claude-litellm" \
  "$prefix/config/codex-litellm" \
  "$prefix/docs" \
  "$prefix/scripts" \
  "$prefix/state/ai-litellm" \
  "$prefix/state/claude-litellm/claude-config" \
  "$prefix/state/codex-litellm/codex-home" \
  "$prefix/state/goose-litellm" \
  "$prefix/state/opencode-litellm"; do
  run mkdir -p "$dir"
done

for dir in \
  "$prefix/state" \
  "$prefix/state/ai-litellm" \
  "$prefix/state/claude-litellm" \
  "$prefix/state/claude-litellm/claude-config" \
  "$prefix/state/codex-litellm" \
  "$prefix/state/codex-litellm/codex-home" \
  "$prefix/state/goose-litellm" \
  "$prefix/state/opencode-litellm"; do
  if (( dry_run )) || [[ -d "$dir" ]]; then
    run chmod 700 "$dir"
  fi
done

install_rendered "$repo_root/config/litellm_config.yaml" "$prefix/config/litellm_config.yaml"
install_rendered "$repo_root/config/ai_litellm_callbacks/__init__.py" "$prefix/config/ai_litellm_callbacks/__init__.py"
install_rendered "$repo_root/config/ai_litellm_callbacks/output_clamp.py" "$prefix/config/ai_litellm_callbacks/output_clamp.py"
install_rendered "$repo_root/config/ai-litellm/context-observations.json" "$prefix/config/ai-litellm/context-observations.json"
install_rendered "$repo_root/config/ai-litellm/lib.zsh" "$prefix/config/ai-litellm/lib.zsh"
install_rendered "$repo_root/config/ai-litellm/settings.json" "$prefix/config/ai-litellm/settings.json"
for descriptor in "$repo_root"/config/ai-litellm/harnesses/*.json(N); do
  install_rendered "$descriptor" "$prefix/config/ai-litellm/harnesses/${descriptor:t}"
done

for pyfile in "$repo_root"/config/ai-litellm/fabric_dash/**/*.py(N); do
  rel="${pyfile#$repo_root/config/ai-litellm/}"
  [[ "$rel" == */tests/* ]] && continue
  install_rendered "$pyfile" "$prefix/config/ai-litellm/$rel"
done
install_rendered "$repo_root/config/ai-litellm/fabric_dash/app.tcss" "$prefix/config/ai-litellm/fabric_dash/app.tcss"

ensure_dash_venv() {
  local venv="$prefix/state/dash-venv"
  # Escape hatch for CI / structural checks: building a venv + pip-installing
  # textual hits the network and is slow. check.zsh sets this so a real install
  # into a throwaway HOME stays fast and offline-safe (the dash module check
  # then skips gracefully). Real user installs leave it unset and build the venv.
  [[ -n "${AI_LITELLM_SKIP_DASH_VENV:-}" ]] && { log "skip dash venv (AI_LITELLM_SKIP_DASH_VENV set)"; return 0; }
  if (( dry_run )); then log "dry-run create dash venv at $venv + pip install textual"; return 0; fi
  command -v python3 >/dev/null 2>&1 || { echo "note: python3 not found — skipping fabric dashboard venv." >&2; return 0; }
  if [[ ! -x "$venv/bin/python" ]]; then
    python3 -m venv "$venv" 2>/dev/null || { echo "note: could not create dashboard venv ($venv); 'fabric' will be unavailable until created." >&2; return 0; }
  fi
  # Non-fatal: install.zsh runs under `set -e`; a failing pip (e.g. offline
  # re-install) must NOT abort the whole install. Guard every pip call.
  "$venv/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  "$venv/bin/python" -m pip install --quiet textual >/dev/null 2>&1 \
    || echo "note: failed to install textual into $venv; run \"$venv/bin/pip install textual\" to enable 'fabric'." >&2
}
ensure_dash_venv

install_rendered "$repo_root/config/claude-litellm/settings.json" "$prefix/config/claude-litellm/settings.json"
install_rendered "$repo_root/config/claude-litellm/shell.zsh" "$prefix/config/claude-litellm/shell.zsh"

install_rendered "$repo_root/config/codex-litellm/settings.json" "$prefix/config/codex-litellm/settings.json"
install_rendered "$repo_root/config/codex-litellm/shell.zsh" "$prefix/config/codex-litellm/shell.zsh"

install_rendered "$repo_root/docs/AI_AGENT_LITELLM_ARCHITECTURE.md" "$prefix/docs/AI_AGENT_LITELLM_ARCHITECTURE.md"
install_executable "$repo_root/scripts/uninstall.zsh" "$prefix/scripts/uninstall.zsh"

for script in ai-litellm claude-litellm codex-litellm goose-litellm opencode-litellm openrouter-key-status litellm-master-key-status fabric; do
  install_executable "$repo_root/bin/$script" "$prefix/bin/$script"
  install_shim "$script"
done

ensure_litellm_master_key

log "Installed ai-litellm-fabric package."
log "Delete with:"
log "  ai-litellm uninstall"
log "  ${(q)prefix}/scripts/uninstall.zsh --prefix ${(q)prefix}"
log "Next:"
log "  ai-litellm key set --keychain openrouter"
log "  claude-litellm --status"
log "  ai-litellm sync"
log "  ai-litellm context doctor"
log "  ai-litellm proxy doctor   # for proxy-backed harnesses/routes"
