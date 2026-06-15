# Codex through the shared local LiteLLM gateway.

if ! typeset -f ai_litellm >/dev/null 2>&1 && [[ -f "${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/config/ai-litellm/lib.zsh" ]]; then
  source "${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/config/ai-litellm/lib.zsh"
elif ! typeset -f ai_litellm >/dev/null 2>&1 && [[ -f "$HOME/.config/ai-litellm/lib.zsh" ]]; then
  source "$HOME/.config/ai-litellm/lib.zsh"
fi

export CODEX_LITELLM_HARNESS="${CODEX_LITELLM_HARNESS:-codex}"
export CODEX_LITELLM_HOME="${CODEX_LITELLM_HOME:-$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" paths.home 2>/dev/null || printf "${AI_LITELLM_STATE_HOME:-${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/state}/codex-litellm")}"
export CODEX_LITELLM_SETTINGS="${CODEX_LITELLM_SETTINGS:-$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" paths.settings 2>/dev/null || printf "$CODEX_LITELLM_HOME/settings.json")}"
export CODEX_LITELLM_CODEX_HOME="${CODEX_LITELLM_CODEX_HOME:-$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" paths.codexHome 2>/dev/null || printf "$CODEX_LITELLM_HOME/codex-home")}"
export CODEX_LITELLM_CONFIG="${CODEX_LITELLM_CONFIG:-$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" paths.config 2>/dev/null || printf "$CODEX_LITELLM_CODEX_HOME/config.toml")}"
export CODEX_LITELLM_MODEL_CATALOG="${CODEX_LITELLM_MODEL_CATALOG:-$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" paths.modelCatalog 2>/dev/null || printf "$CODEX_LITELLM_HOME/model-catalog.json")}"

_codex_litellm_json() {
  ai_litellm_json_file "$CODEX_LITELLM_SETTINGS" "$1"
}

_codex_litellm_alias_target() {
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = data.aliases && data.aliases[process.argv[2]];
if (!value) process.exit(1);
console.log(value);
' "$CODEX_LITELLM_SETTINGS" "$1"
}

_codex_litellm_resolve_route_model() {
  local requested="$1"
  if [[ -z "$requested" ]]; then
    requested="$(_codex_litellm_default_alias)"
  fi

  ruby -ryaml -rjson -e '
config_path, settings_path, descriptor_path, requested = ARGV
config = (YAML.load_file(config_path, aliases: true) rescue YAML.load_file(config_path))
settings = JSON.parse(File.read(settings_path))
descriptor = JSON.parse(File.read(descriptor_path))
entries = Array(config["model_list"])
aliases = settings["aliases"] || {}
default_model = descriptor.dig("models", "default") || "gpt-5.5"
target = requested.to_s.empty? ? default_model : requested.to_s
target = aliases[target] if aliases[target]

backend = ->(entry) { entry.dig("litellm_params", "model").to_s }
normalize = ->(value) { value.to_s.sub(%r{\Aopenrouter/}, "") }
codex_slug = ->(name) { name.to_s.match?(/\A(?:gpt-|codex-|local-)/) }
preferred = []
preferred << default_model
aliases.each_value { |value| preferred << value }
Array(descriptor.dig("models", "localCatalogEntries")).each { |entry| preferred << entry["slug"] }
preferred = preferred.compact.uniq

pick = lambda do |matches|
  selected = nil
  preferred.each do |name|
    found = matches.find { |entry| entry["model_name"].to_s == name }
    if found
      selected = found
      break
    end
  end
  selected || matches.find { |entry| codex_slug.call(entry["model_name"]) } || matches.first
end

exact = entries.find { |entry| entry["model_name"].to_s == target }
if exact
  if codex_slug.call(exact["model_name"])
    puts exact["model_name"]
    exit
  end
  same_backend = entries.select { |entry| backend.call(entry) == backend.call(exact) }
  picked = pick.call(same_backend)
  puts((picked || exact)["model_name"])
  exit
end

matches = entries.select do |entry|
  provider_model = backend.call(entry)
  provider_model == target || normalize.call(provider_model) == target
end
picked = pick.call(matches)
exit 1 unless picked && picked["model_name"]
puts picked["model_name"]
' "$AI_LITELLM_CONFIG" "$CODEX_LITELLM_SETTINGS" "$(ai_litellm_harness_descriptor "$CODEX_LITELLM_HARNESS")" "$requested"
}

_codex_litellm_route_target() {
  ai_litellm_model_backend "$1"
}

_codex_litellm_alias_lines() {
  echo "Native Codex model routes:"
  if [[ -f "$CODEX_LITELLM_MODEL_CATALOG" ]] && command -v jq >/dev/null 2>&1; then
    jq -r ".models[].slug" "$CODEX_LITELLM_MODEL_CATALOG" | while IFS= read -r model; do
      backend_model="$(_codex_litellm_route_target "$model" 2>/dev/null || printf 'unmapped')"
      printf '  %s -> %s\n' "$model" "$backend_model"
    done
  else
    ai_litellm_model_names | grep -E '^(gpt-|codex-)' | while IFS= read -r model; do
      backend_model="$(_codex_litellm_route_target "$model" 2>/dev/null || printf 'unmapped')"
      printf '  %s -> %s\n' "$model" "$backend_model"
    done
  fi

  echo
  echo "Shortcuts:"
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const [shortcut, model] of Object.entries(data.aliases || {})) {
  console.log(`${shortcut}\t${model}`);
}
' "$CODEX_LITELLM_SETTINGS" | while IFS=$'\t' read -r shortcut model; do
    backend_model="$(_codex_litellm_route_target "$model" 2>/dev/null || printf 'unmapped')"
    printf '  %s -> %s -> %s\n' "$shortcut" "$model" "$backend_model"
  done
}

_codex_litellm_default_alias() {
  local configured_model
  configured_model="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" models.default 2>/dev/null)"
  if [[ -n "$configured_model" ]]; then
    printf '%s\n' "$configured_model"
  else
    printf 'gpt-5.5\n'
  fi
}

_codex_litellm_is_codex_subcommand() {
  local candidate="$1"
  ai_litellm_harness_json_array "$CODEX_LITELLM_HARNESS" adapterConfig.subcommands 2>/dev/null | grep -Fx -- "$candidate" >/dev/null
}

_codex_litellm_resolve_model() {
  local requested="$1"
  if [[ -z "$requested" ]]; then
    requested="$(_codex_litellm_default_alias)"
  fi

  _codex_litellm_resolve_route_model "$requested"
}

codex-litellm-render-config() {
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$CODEX_LITELLM_HARNESS")" || return 1
  mkdir -p "$CODEX_LITELLM_CODEX_HOME"

  node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const configPath = process.argv[2];
const apiBase = process.argv[3];
const codexHome = descriptor.paths.codexHome;
const catalog = descriptor.paths.modelCatalog;
const models = descriptor.models || {};
const provider = descriptor.provider || {};
const adapter = descriptor.adapterConfig || {};
const q = (value) => JSON.stringify(String(value));
const bool = (value) => value ? "true" : "false";
const lines = [];

lines.push(`model = ${q(models.default || "gpt-5.5")}`);
lines.push(`model_provider = ${q(provider.name || "litellm")}`);
lines.push(`model_catalog_json = ${q(catalog)}`);
lines.push(`model_reasoning_summary = ${q(adapter.modelReasoningSummary || "none")}`);
lines.push(`model_supports_reasoning_summaries = ${bool(adapter.modelSupportsReasoningSummaries)}`);
lines.push(`approval_policy = ${q(adapter.approvalPolicy || "on-request")}`);
lines.push(`sandbox_mode = ${q(adapter.sandboxMode || "workspace-write")}`);
lines.push(`personality = ${q(adapter.personality || "pragmatic")}`);
lines.push(`model_reasoning_effort = ${q(adapter.modelReasoningEffort || "xhigh")}`);
lines.push("");
lines.push(`[model_providers.${provider.name || "litellm"}]`);
lines.push(`name = ${q(provider.displayName || "LiteLLM")}`);
lines.push(`base_url = ${q(apiBase)}`);
lines.push(`env_key = ${q(provider.auth?.env || "LITELLM_MASTER_KEY")}`);
lines.push(`wire_api = ${q(provider.wireApi || "responses")}`);
lines.push(`supports_websockets = ${bool(provider.supportsWebsockets)}`);
lines.push("");
lines.push("[features]");
for (const [key, value] of Object.entries(adapter.features || {})) {
  lines.push(`${key} = ${bool(value)}`);
}
lines.push("");
lines.push("[shell_environment_policy]");
lines.push(`inherit = ${q(adapter.shellEnvironmentPolicy?.inherit || "core")}`);
for (const [project, trust] of Object.entries(adapter.projectTrust || {})) {
  lines.push("");
  lines.push(`[projects.${q(project)}]`);
  lines.push(`trust_level = ${q(trust)}`);
}
if (adapter.availabilityNux && Object.keys(adapter.availabilityNux).length) {
  lines.push("");
  lines.push("[tui.model_availability_nux]");
  for (const [model, value] of Object.entries(adapter.availabilityNux)) {
    lines.push(`${q(model)} = ${Number(value)}`);
  }
}
lines.push("");
fs.mkdirSync(codexHome, {recursive: true});
const tmp = `${configPath}.tmp.${process.pid}`;
fs.writeFileSync(tmp, lines.join("\n"), {mode: 0o600});
fs.renameSync(tmp, configPath);
' "$descriptor" "$CODEX_LITELLM_CONFIG" "$(ai_litellm_api_base_url)"
}

_codex_litellm_run_codex() {
  local master_key
  master_key="$(ai_litellm_master_key)" || return 1
  codex-litellm-render-config >/dev/null || return $?

  local codex_command auth_env isolation_env
  codex_command="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" command 2>/dev/null || printf 'codex')"
  auth_env="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" provider.auth.env 2>/dev/null || printf 'LITELLM_MASTER_KEY')"
  isolation_env="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" isolation.env 2>/dev/null || printf 'CODEX_HOME')"

  ai_litellm_harness_exec_env "$CODEX_LITELLM_HARNESS" \
    "$isolation_env=$CODEX_LITELLM_CODEX_HOME" \
    "$auth_env=$master_key" \
    -- \
    "$codex_command" -c "model_providers.litellm.base_url=\"$(ai_litellm_api_base_url)\"" "$@"
}

codex-litellm-list() {
  echo "Codex default:"
  echo "  config model -> $(_codex_litellm_default_alias)"
  echo "  catalog -> $CODEX_LITELLM_MODEL_CATALOG"
  echo
  _codex_litellm_alias_lines
  echo
  ai_litellm_list
}

codex-litellm-status() {
  echo "CODEX_HOME: $CODEX_LITELLM_CODEX_HOME"
  echo "Config:     $CODEX_LITELLM_CONFIG"
  echo "Settings:   $CODEX_LITELLM_SETTINGS"
  echo "Catalog:    $CODEX_LITELLM_MODEL_CATALOG"
  echo "Provider:   litellm"
  echo "Base URL:   $(ai_litellm_api_base_url)"
  local default_model route_target
  default_model="$(_codex_litellm_resolve_model "$(_codex_litellm_default_alias)" 2>/dev/null || printf 'unresolved')"
  route_target="$(_codex_litellm_route_target "$default_model" 2>/dev/null || printf 'raw/direct')"
  echo "Default:    config model -> $default_model -> $route_target"
  ai_litellm_status
}

codex-litellm-refresh-catalog() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Missing jq; install jq or regenerate $CODEX_LITELLM_MODEL_CATALOG manually." >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/codex-litellm-model-catalog.XXXXXX")" || return 1

  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$CODEX_LITELLM_HARNESS")" || return 1
  local codex_command
  codex_command="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" command 2>/dev/null || printf 'codex')"
  local local_catalog_json
  local_catalog_json="$(ruby -ryaml -rjson -e '
registry = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
descriptor = JSON.parse(File.read(ARGV[1]))
configured = Array(descriptor.dig("models", "localCatalogEntries"))
entries = []
seen = {}
configured.each do |entry|
  next unless entry["slug"]
  entries << entry
  seen[entry["slug"]] = true
end
Array(registry["model_list"]).each do |entry|
  slug = entry["model_name"].to_s
  next unless slug.start_with?("local-")
  next if seen[slug]
  backend = entry.dig("litellm_params", "model").to_s.sub(%r{\Aopenai/}, "")
  entries << {
    "slug" => slug,
    "displayName" => slug,
    "description" => "Local model #{backend} served through LiteLLM.",
    "priority" => 80,
    "defaultReasoningLevel" => "low"
  }
  seen[slug] = true
end
puts JSON.generate(entries)
' "$AI_LITELLM_CONFIG" "$descriptor")" || return 1

  # Codex has no reliable request-body output cap, so catalog context windows
  # are shaped to the safe input budget derived from the descriptor reservation
  # policy rather than the raw provider window.
  local catalog_context_json
  catalog_context_json="$(ai_litellm_codex_catalog_context_map "$CODEX_LITELLM_HARNESS" 2>/dev/null)" || catalog_context_json="{}"
  [[ -n "$catalog_context_json" ]] || catalog_context_json="{}"

  # `codex debug models` is an external binary that can hang (auth/network/GUI
  # subprocess). Bound it so a stuck codex never hangs the whole sync — on
  # timeout the pipe fails and the existing catalog is kept (see the || below).
  CODEX_HOME="$CODEX_LITELLM_CODEX_HOME" ai_litellm_run_timeout "${AI_LITELLM_CODEX_PROBE_TIMEOUT:-30}" "$codex_command" debug models --bundled \
    | node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const catalogContext = JSON.parse(process.argv[2] || "{}");
const entries = JSON.parse(process.argv[3] || "[]");
const catalog = JSON.parse(fs.readFileSync(0, "utf8"));
catalog.models = (catalog.models || []).map((model) => {
  const next = {...model, supports_search_tool: false};
  delete next.apply_patch_tool_type;
  delete next.web_search_tool_type;
  return next;
});
const localSlugs = new Set(entries.map((entry) => entry.slug));
catalog.models = catalog.models.filter((model) => !localSlugs.has(model.slug));
const baseSlug = descriptor.models?.catalogBaseSlug || "gpt-5.4-mini";
const base = catalog.models.find((model) => model.slug === baseSlug) || catalog.models[0];
if (!base && entries.length) {
  console.error("No base Codex catalog model found");
  process.exit(1);
}
for (const entry of entries) {
  catalog.models.push({
    ...base,
    slug: entry.slug,
    display_name: entry.displayName,
    description: entry.description,
    priority: entry.priority,
    default_reasoning_level: entry.defaultReasoningLevel || base.default_reasoning_level,
    additional_speed_tiers: [],
    service_tiers: [],
    availability_nux: null,
    upgrade: null,
    supports_search_tool: false
  });
}
// Stamp the safe input window per slug from the single source plus Codex
// reservation policy. Reset auto_compact_token_limit to null so Codex derives
// compaction from the corrected window instead of a stale inherited absolute.
catalog.models = catalog.models.map((model) => {
  const ctx = catalogContext[model.slug];
  if (ctx == null) return model;
  return { ...model, context_window: ctx, max_context_window: ctx, auto_compact_token_limit: null };
});
process.stdout.write(JSON.stringify(catalog, null, 2) + "\n");
	' "$descriptor" "$catalog_context_json" "$local_catalog_json" > "$tmp" || {
      rm -f "$tmp"
      echo "codex catalog refresh failed: 'codex debug models' errored or timed out (>${AI_LITELLM_CODEX_PROBE_TIMEOUT:-30}s); existing catalog kept." >&2
      return 1
    }

  chmod 600 "$tmp"
  mv "$tmp" "$CODEX_LITELLM_MODEL_CATALOG"
  echo "Wrote $CODEX_LITELLM_MODEL_CATALOG"
}

codex-litellm-route-info() {
  local requested="$1"
  local model_filter
  if [[ -n "$requested" ]]; then
    model_filter="$(_codex_litellm_alias_target "$requested" 2>/dev/null)" || model_filter="$requested"
  fi
  ai_litellm_route_info "$model_filter"
}

codex-litellm-start() {
  ai_litellm_start "$@"
}

codex-litellm-stop() {
  ai_litellm_stop "$@"
}

codex-litellm-restart() {
  ai_litellm_restart "$@"
}

codex-litellm() {
  if ! typeset -f ai_litellm >/dev/null 2>&1; then
    echo "Missing shared LiteLLM library: $AI_LITELLM_CONFIG_HOME/ai-litellm/lib.zsh" >&2
    return 1
  fi

  case "$1" in
    -h|--help)
      echo "Usage: codex-litellm [alias|model_name|provider_model] [codex args...]"
      echo "       codex-litellm exec \"prompt\""
      echo "       codex-litellm gpt-5.5 exec \"prompt\""
      echo "       codex-litellm openrouter/deepseek/deepseek-v4-pro exec \"prompt\""
      echo "       codex-litellm --list|--status|--route-info [model]|--refresh-catalog   (codex-specific)"
      echo "Reasoning defaults: ai-litellm harness reasoning [set|unset] codex"
      echo "Proxy lifecycle moved to: ai-litellm proxy start|stop|restart|logs|doctor"
      return 0
      ;;
    -V|--version)
      local codex_command
      codex_command="$(ai_litellm_harness_json "$CODEX_LITELLM_HARNESS" command 2>/dev/null || printf 'codex')"
      CODEX_HOME="$CODEX_LITELLM_CODEX_HOME" "$codex_command" --version
      return $?
      ;;
    --list)
      codex-litellm-list
      return $?
      ;;
    --status)
      codex-litellm-status
      return $?
      ;;
    --refresh-catalog)
      codex-litellm-refresh-catalog
      return $?
      ;;
    --route-info)
      shift
      codex-litellm-route-info "$@"
      return $?
      ;;
    --start)
      echo "codex-litellm --start is deprecated; use 'ai-litellm proxy start'" >&2
      codex-litellm-start
      return $?
      ;;
    --stop)
      echo "codex-litellm --stop is deprecated; use 'ai-litellm proxy stop'" >&2
      codex-litellm-stop
      return $?
      ;;
    --restart)
      echo "codex-litellm --restart is deprecated; use 'ai-litellm proxy restart'" >&2
      codex-litellm-restart
      return $?
      ;;
    --logs)
      echo "codex-litellm --logs is deprecated; use 'ai-litellm proxy logs'" >&2
      shift
      ai_litellm_logs "$@"
      return $?
      ;;
    --doctor)
      echo "codex-litellm --doctor is deprecated; use 'ai-litellm proxy doctor'" >&2
      shift
      ai_litellm_doctor "$@"
      return $?
      ;;
  esac

  local requested="" first_arg="$1"
  local explicit_model=0
  if [[ -n "$first_arg" && "$first_arg" != -* ]] && ! _codex_litellm_is_codex_subcommand "$first_arg"; then
    if _codex_litellm_resolve_model "$first_arg" >/dev/null 2>&1; then
      requested="$first_arg"
      explicit_model=1
      shift
    fi
  fi

  local model
  if (( explicit_model )); then
    model="$(_codex_litellm_resolve_model "$requested")" || {
      echo "Unknown codex-litellm alias, LiteLLM model_name, or provider model: $requested" >&2
      return 1
    }

    ai_litellm_model_runtime_ready "$model" || return $?
  else
    model="$(_codex_litellm_resolve_model "$(_codex_litellm_default_alias)" 2>/dev/null || true)"
    [[ -z "$model" ]] || ai_litellm_model_runtime_ready "$model" || return $?
  fi

  ai_litellm_start >/dev/null || return $?
  if [[ ! -f "$CODEX_LITELLM_MODEL_CATALOG" ]]; then
    codex-litellm-refresh-catalog >/dev/null || return $?
  fi

  if (( explicit_model )); then
    _codex_litellm_run_codex -m "$model" "$@"
  else
    _codex_litellm_run_codex "$@"
  fi
}
