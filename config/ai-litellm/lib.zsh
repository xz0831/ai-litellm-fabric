# Shared LiteLLM proxy management for local agent wrappers.

export AI_LITELLM_FABRIC_HOME="${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}"
export AI_LITELLM_CONFIG_HOME="${AI_LITELLM_CONFIG_HOME:-$AI_LITELLM_FABRIC_HOME/config}"
export AI_LITELLM_STATE_HOME="${AI_LITELLM_STATE_HOME:-$AI_LITELLM_FABRIC_HOME/state}"
export AI_LITELLM_BIN_DIR="${AI_LITELLM_BIN_DIR:-$AI_LITELLM_FABRIC_HOME/bin}"
export AI_LITELLM_HOME="${AI_LITELLM_HOME:-$AI_LITELLM_STATE_HOME/ai-litellm}"
export AI_LITELLM_CONFIG="${AI_LITELLM_CONFIG:-$AI_LITELLM_CONFIG_HOME/litellm_config.yaml}"
export AI_LITELLM_SETTINGS="${AI_LITELLM_SETTINGS:-$AI_LITELLM_CONFIG_HOME/ai-litellm/settings.json}"
export AI_LITELLM_HARNESSES_DIR="${AI_LITELLM_HARNESSES_DIR:-$AI_LITELLM_CONFIG_HOME/ai-litellm/harnesses}"
export AI_LITELLM_ENV="${AI_LITELLM_ENV:-$AI_LITELLM_HOME/env}"
export AI_LITELLM_PID_FILE="${AI_LITELLM_PID_FILE:-$AI_LITELLM_HOME/litellm.pid}"
export AI_LITELLM_LOCK_DIR="${AI_LITELLM_LOCK_DIR:-$AI_LITELLM_HOME/litellm.lock}"
export AI_LITELLM_LOG_FILE="${AI_LITELLM_LOG_FILE:-$AI_LITELLM_HOME/litellm.log}"
export AI_LITELLM_CONFIG_HASH_FILE="${AI_LITELLM_CONFIG_HASH_FILE:-$AI_LITELLM_HOME/litellm.config.sha256}"
export AI_LITELLM_STARTED_AT_FILE="${AI_LITELLM_STARTED_AT_FILE:-$AI_LITELLM_HOME/litellm.started_at}"
export AI_LITELLM_REASONING_OBS_FILE="${AI_LITELLM_REASONING_OBS_FILE:-$AI_LITELLM_HOME/reasoning-observations.json}"
export AI_LITELLM_LOCK_MAX_AGE_SECONDS="${AI_LITELLM_LOCK_MAX_AGE_SECONDS:-300}"
export AI_LITELLM_LEGACY_ENV="${AI_LITELLM_LEGACY_ENV:-$HOME/.config/ai-litellm/env}"
export AI_LITELLM_LEGACY_PID_FILE="${AI_LITELLM_LEGACY_PID_FILE:-$HOME/.config/ai-litellm/litellm.pid}"
export AI_LITELLM_LEGACY_LOG_FILE="${AI_LITELLM_LEGACY_LOG_FILE:-$HOME/.config/ai-litellm/litellm.log}"
export AI_LITELLM_LEGACY_CLAUDE_ENV="${AI_LITELLM_LEGACY_CLAUDE_ENV:-$HOME/.config/claude-litellm/env}"
export AI_LITELLM_LEGACY_CLAUDE_PID_FILE="${AI_LITELLM_LEGACY_CLAUDE_PID_FILE:-$HOME/.config/claude-litellm/litellm.pid}"
export AI_LITELLM_LEGACY_CLAUDE_LOG_FILE="${AI_LITELLM_LEGACY_CLAUDE_LOG_FILE:-$HOME/.config/claude-litellm/litellm.log}"
export OPENROUTER_KEYCHAIN_SERVICE="${OPENROUTER_KEYCHAIN_SERVICE:-openrouter-api-key}"
export OPENROUTER_KEYCHAIN_ACCOUNT="${OPENROUTER_KEYCHAIN_ACCOUNT:-$USER}"
export LITELLM_MASTER_KEYCHAIN_SERVICE="${LITELLM_MASTER_KEYCHAIN_SERVICE:-litellm-master-key}"
export LITELLM_MASTER_KEYCHAIN_ACCOUNT="${LITELLM_MASTER_KEYCHAIN_ACCOUNT:-$USER}"

ai_litellm_json_file() {
  local file="$1"
  local json_path="$2"
  [[ -f "$file" ]] || return 1
  node -e '
const fs = require("fs");
const file = process.argv[1];
const path = process.argv[2].split(".");
let value = JSON.parse(fs.readFileSync(file, "utf8"));
for (const key of path) value = value == null ? undefined : value[key];
if (value == null) process.exit(1);
if (typeof value === "object") console.log(JSON.stringify(value));
else console.log(String(value));
' "$file" "$json_path"
}

ai_litellm_json_array() {
  local file="$1"
  local json_path="$2"
  [[ -f "$file" ]] || return 1
  node -e '
const fs = require("fs");
const file = process.argv[1];
const path = process.argv[2].split(".");
let value = JSON.parse(fs.readFileSync(file, "utf8"));
for (const key of path) value = value == null ? undefined : value[key];
if (!Array.isArray(value)) process.exit(1);
for (const item of value) console.log(String(item));
' "$file" "$json_path"
}

ai_litellm_template_value() {
  local value="$1"
  value="${value//\{\{ai.baseUrl\}\}/$(ai_litellm_base_url)}"
  value="${value//\{\{ai.apiBaseUrl\}\}/$(ai_litellm_api_base_url)}"
  printf '%s\n' "$value"
}

ai_litellm_json() {
  ai_litellm_json_file "$AI_LITELLM_SETTINGS" "$1"
}

ai_litellm_env_value() {
  local key="$1"
  local env_file
  for env_file in "$AI_LITELLM_ENV" "$AI_LITELLM_LEGACY_ENV" "$AI_LITELLM_LEGACY_CLAUDE_ENV"; do
    [[ -f "$env_file" ]] || continue
    node -e '
const fs = require("fs");
const file = process.argv[1];
const wanted = process.argv[2];
const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
for (let line of lines) {
  line = line.trim();
  if (!line || line.startsWith("#")) continue;
  if (line.startsWith("export ")) line = line.slice("export ".length).trimStart();
  const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
  if (!match || match[1] !== wanted) continue;
  let value = match[2];
  if (
    value.length >= 2 &&
    ((value.startsWith("\"") && value.endsWith("\"")) ||
     (value.startsWith("'") && value.endsWith("'")))
  ) {
    value = value.slice(1, -1);
  }
  if (!value) process.exit(1);
  console.log(value);
  process.exit(0);
}
process.exit(1);
' "$env_file" "$key" && return 0
  done
  return 1
}

ai_litellm_keychain_value() {
  local service="$1"
  local account="$2"
  command -v security >/dev/null 2>&1 || return 1
  security find-generic-password -s "$service" -a "$account" -w 2>/dev/null
}

ai_litellm_openrouter_key() {
  if [[ -n "$OPENROUTER_API_KEY" ]]; then
    printf '%s\n' "$OPENROUTER_API_KEY"
    return 0
  fi

  ai_litellm_env_value OPENROUTER_API_KEY 2>/dev/null && return 0
  ai_litellm_keychain_value "$OPENROUTER_KEYCHAIN_SERVICE" "$OPENROUTER_KEYCHAIN_ACCOUNT"
}

ai_litellm_master_key() {
  if [[ -n "$LITELLM_MASTER_KEY" ]]; then
    printf '%s\n' "$LITELLM_MASTER_KEY"
    return 0
  fi

  ai_litellm_env_value LITELLM_MASTER_KEY 2>/dev/null && return 0
  ai_litellm_keychain_value "$LITELLM_MASTER_KEYCHAIN_SERVICE" "$LITELLM_MASTER_KEYCHAIN_ACCOUNT" && return 0

  local configured_key
  configured_key="$(ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
value = config.dig("general_settings", "master_key") rescue nil
puts value if value
' "$AI_LITELLM_CONFIG" 2>/dev/null)"

  if [[ -z "$configured_key" || "$configured_key" == os.environ/* ]]; then
    return 1
  fi

  printf '%s\n' "$configured_key"
}

ai_litellm_host() {
  ai_litellm_json server.host 2>/dev/null || printf '127.0.0.1\n'
}

ai_litellm_port() {
  ai_litellm_json server.port 2>/dev/null || printf '4000\n'
}

ai_litellm_base_url() {
  printf 'http://%s:%s\n' "$(ai_litellm_host)" "$(ai_litellm_port)"
}

ai_litellm_api_base_url() {
  printf '%s/v1\n' "$(ai_litellm_base_url)"
}

ai_litellm_curl_auth() {
  local master_key="$1"
  shift
  if [[ -n "$master_key" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$master_key" | curl -K - "$@"
  else
    curl "$@"
  fi
}

ai_litellm_model_names() {
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
Array(config["model_list"]).each do |entry|
  name = entry["model_name"]
  puts name if name
end
' "$AI_LITELLM_CONFIG"
}

ai_litellm_model_exists() {
  local model_name="$1"
  ai_litellm_model_names | grep -Fx -- "$model_name" >/dev/null
}

ai_litellm_model_backend() {
  local model_name="$1"
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
target = ARGV[1]
models = Array(config["model_list"]).select { |entry| entry["model_name"] == target }
backends = models.map { |entry| entry.dig("litellm_params", "model") }.compact
exit 1 if backends.empty?
puts backends.join(",")
' "$AI_LITELLM_CONFIG" "$model_name"
}

ai_litellm_litellm_setting() {
  local key="$1"
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
value = config.dig("litellm_settings", ARGV[1]) rescue nil
exit 1 if value.nil?
puts value
' "$AI_LITELLM_CONFIG" "$key"
}

ai_litellm_litellm_python() {
  local litellm_bin shebang python_candidate
  litellm_bin="$(command -v litellm 2>/dev/null)" || return 1
  if [[ -f "$litellm_bin" ]]; then
    shebang="$(head -n 1 "$litellm_bin" 2>/dev/null || true)"
    if [[ "$shebang" == '#!'* ]]; then
      python_candidate="${shebang#\#!}"
      python_candidate="${python_candidate%% *}"
      if [[ -x "$python_candidate" ]]; then
        printf '%s\n' "$python_candidate"
        return 0
      fi
    fi
  fi

  if python3 -c 'import litellm' >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi

  return 1
}

# Resolve the per-model token limits from the single source (litellm_config.yaml
# model_info, anchors already expanded by the YAML parser). Prints JSON
# {"context":N,"output":M} for the given surface model_name, or exits 1 when the
# model has no model_info.max_input_tokens. This is the one reader every harness
# generator/launcher derives from.
ai_litellm_model_limits() {
  local model_name="$1"
  ruby -ryaml -rjson -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
target = ARGV[1]
entry = Array(config["model_list"]).find { |e| e["model_name"] == target }
exit 1 if entry.nil?
mi = entry["model_info"] || {}
ctx = mi["max_input_tokens"]
out = mi["max_output_tokens"]
exit 1 if ctx.nil?
result = {"context" => ctx}
result["output"] = out unless out.nil?
puts JSON.generate(result)
' "$AI_LITELLM_CONFIG" "$model_name"
}

# Resolve a harness-specific output reservation from the descriptor. This is
# intentionally separate from model_info.max_output_tokens, which is a capability
# ceiling. The reservation is what a harness should ask the provider to reserve
# on each request when the provider accounts input + reserved output together.
ai_litellm_harness_output_budget() {
  local harness="$1"
  local selection="$2"
  local model_name="$3"
  local descriptor limits
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1
  limits="$(ai_litellm_model_limits "$model_name" 2>/dev/null)" || return 1

  node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const selection = process.argv[2] || "";
const model = process.argv[3] || "";
const limits = JSON.parse(process.argv[4] || "{}");
const policy = descriptor.adapterConfig?.outputReservation || {};

const positiveInt = (value) => {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : null;
};
const pick = (candidates) => {
  for (const [source, value] of candidates) {
    const n = positiveInt(value);
    if (n != null) return {source, value: n};
  }
  return null;
};

const context = positiveInt(limits.context);
const capability = positiveInt(limits.output);
const configuredHeadroom = positiveInt(policy.tokenizerHeadroom) ?? 0;
const configuredMinimumInput = positiveInt(policy.minimumInput) ?? 32768;
let chosen = pick([
  [`adapterConfig.outputReservation.perSelection.${selection}`, policy.perSelection?.[selection]],
  [`adapterConfig.outputReservation.perTier.${selection}`, policy.perTier?.[selection]],
  [`adapterConfig.outputReservation.perModel.${model}`, policy.perModel?.[model]],
  ["adapterConfig.outputReservation.default", policy.default],
]);

if (!chosen) {
  if (capability == null) process.exit(1);
  chosen = {source: "capability-clamped-default", value: Math.min(capability, 32000)};
}

let reservation = chosen.value;
let source = chosen.source;
if (capability != null && reservation > capability) {
  reservation = capability;
  source += "+capabilityClamp";
}
let headroom = configuredHeadroom;
let minimumInput = configuredMinimumInput;
if (context != null) {
  headroom = Math.min(headroom, Math.floor(context * 0.1));
  minimumInput = Math.min(minimumInput, Math.max(1, Math.floor(context * 0.5)));
  const maxReservationForMinimumInput = context - headroom - minimumInput;
  if (maxReservationForMinimumInput < 1) {
    reservation = 1;
    headroom = Math.max(0, context - minimumInput - reservation);
    source += "+tinyWindowClamp";
  } else if (reservation > maxReservationForMinimumInput) {
    reservation = maxReservationForMinimumInput;
    source += "+minimumInputClamp";
  }
}

const effectiveInput = context == null ? null : Math.max(0, context - reservation - headroom);
console.log(JSON.stringify({
  context,
  capability,
  reservation,
  tokenizerHeadroom: headroom,
  minimumInput,
  effectiveInput,
  source,
}));
' "$descriptor" "$selection" "$model_name" "$limits"
}

# Emit the full surface model_name -> max_input_tokens map (JSON) from the single
# source. Generators (Codex catalog) and the doctor staleness check both consume
# this so the derivation logic lives in exactly one place.
ai_litellm_limits_map() {
  ruby -ryaml -rjson -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
out = {}
Array(config["model_list"]).each do |e|
  mi = e["model_info"] || {}
  next unless mi["max_input_tokens"]
  out[e["model_name"]] = mi["max_input_tokens"]
end
puts JSON.generate(out)
' "$AI_LITELLM_CONFIG"
}

ai_litellm_codex_catalog_context_map() {
  local harness="${1:-codex}"
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1
  ruby -ryaml -rjson -e '
def positive_int(value)
  n = value.to_i
  n.positive? ? n : nil
end

def pick_reservation(policy, selection, model)
  [
    ["perSelection.#{selection}", policy.dig("perSelection", selection)],
    ["perTier.#{selection}", policy.dig("perTier", selection)],
    ["perModel.#{model}", policy.dig("perModel", model)],
    ["default", policy["default"]]
  ].each do |_source, value|
    n = positive_int(value)
    return n if n
  end
  nil
end

def effective_input(policy, selection, model, context, output)
  return context if policy.empty?
  capability = positive_int(output)
  reservation = pick_reservation(policy, selection, model)
  reservation ||= [capability, 32000].compact.min
  return context unless reservation
  reservation = capability if capability && reservation > capability

  headroom = positive_int(policy["tokenizerHeadroom"]) || 0
  minimum_input = positive_int(policy["minimumInput"]) || 32768
  headroom = [headroom, (context * 0.1).floor].min
  minimum_input = [minimum_input, [1, (context * 0.5).floor].max].min
  max_reservation = context - headroom - minimum_input
  if max_reservation < 1
    reservation = 1
    headroom = [0, context - minimum_input - reservation].max
  elsif reservation > max_reservation
    reservation = max_reservation
  end
  [0, context - reservation - headroom].max
end

config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
descriptor = JSON.parse(File.read(ARGV[1]))
policy = descriptor.dig("adapterConfig", "outputReservation") || {}
out = {}
Array(config["model_list"]).each do |e|
  name = e["model_name"]
  mi = e["model_info"] || {}
  context = positive_int(mi["max_input_tokens"])
  next unless name && context
  backend = e.dig("litellm_params", "model").to_s
  api_key = e.dig("litellm_params", "api_key").to_s
  local_runtime = backend.start_with?("openai/local-") || api_key == "none"
  # C2 is an OpenRouter/shared-window exposure. Local runtimes are already
  # policy-capped below their observed serving window, so do not shrink them
  # further through the Codex compatibility catalog.
  out[name] = local_runtime ? context : effective_input(policy, name, name, context, mi["max_output_tokens"])
end
puts JSON.generate(out)
' "$AI_LITELLM_CONFIG" "$descriptor"
}

ai_litellm_harness_descriptor() {
  local harness="$1"
  local path="$AI_LITELLM_HARNESSES_DIR/$harness.json"
  [[ -f "$path" ]] || return 1
  printf '%s\n' "$path"
}

ai_litellm_harness_json() {
  local harness="$1"
  local json_path="$2"
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1
  ai_litellm_json_file "$descriptor" "$json_path"
}

ai_litellm_harness_json_array() {
  local harness="$1"
  local json_path="$2"
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1
  ai_litellm_json_array "$descriptor" "$json_path"
}

ai_litellm_harness_names() {
  [[ -d "$AI_LITELLM_HARNESSES_DIR" ]] || return 0
  local descriptor
  for descriptor in "$AI_LITELLM_HARNESSES_DIR"/*.json(N); do
    [[ "${descriptor:t}" == "schema.json" ]] && continue
    printf '%s\n' "${descriptor:t:r}"
  done
}

ai_litellm_harness_adapter_names() {
  local schema="$AI_LITELLM_HARNESSES_DIR/schema.json"
  [[ -f "$schema" ]] || return 1
  node -e '
const fs = require("fs");
const schema = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const adapter of schema.properties?.adapter?.enum || []) console.log(adapter);
' "$schema"
}

ai_litellm_harness_validate() {
  local harness="$1"
  local descriptor adapter schema
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || {
    echo "Missing harness descriptor: $AI_LITELLM_HARNESSES_DIR/$harness.json" >&2
    return 1
  }
  schema="$AI_LITELLM_HARNESSES_DIR/schema.json"

  node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const required = schema.required || [];
const adapterEnum = new Set(schema.properties?.adapter?.enum || []);
const errors = [];
const isObject = (value) => value && typeof value === "object" && !Array.isArray(value);
const hasString = (object, key) => typeof object?.[key] === "string" && object[key].length > 0;
const requireString = (object, key, label) => {
  if (!hasString(object, key)) errors.push(`${label}.${key} must be a non-empty string`);
};
const requireStringArray = (object, key, label, {allowEmpty = false} = {}) => {
  const value = object?.[key];
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0) || value.some((item) => typeof item !== "string" || item.length === 0)) {
    errors.push(`${label}.${key} must be ${allowEmpty ? "an" : "a non-empty"} array of strings`);
  }
};
const requirePositiveInteger = (object, key, label) => {
  const value = object?.[key];
  if (!Number.isInteger(value) || value <= 0) errors.push(`${label}.${key} must be a positive integer`);
};
const missing = required.filter((key) => descriptor[key] == null);
if (missing.length) {
  errors.push(`missing descriptor fields: ${missing.join(", ")}`);
}
if (descriptor.schemaVersion !== 1) {
  errors.push(`unsupported schemaVersion: ${descriptor.schemaVersion}`);
}
if (!adapterEnum.has(descriptor.adapter)) {
  errors.push(`unsupported adapter: ${descriptor.adapter}`);
}
requireString(descriptor, "name", "descriptor");
requireString(descriptor, "adapter", "descriptor");
requireString(descriptor, "command", "descriptor");
if (!isObject(descriptor.paths)) errors.push("paths must be an object");
if (!isObject(descriptor.isolation)) errors.push("isolation must be an object");
requireString(descriptor.isolation || {}, "kind", "isolation");
requireString(descriptor.isolation || {}, "env", "isolation");
if (descriptor.isolation?.scrubEnv != null) requireStringArray(descriptor.isolation, "scrubEnv", "isolation", {allowEmpty: true});

const provider = descriptor.provider || {};
const auth = provider.auth || {};
if (descriptor.provider != null) {
  requireString(provider, "baseUrl", "provider");
  if (provider.auth != null) {
    requireString(auth, "mode", "provider.auth");
    requireString(auth, "env", "provider.auth");
    requireString(auth, "source", "provider.auth");
  }
}

const paths = descriptor.paths || {};
const models = descriptor.models || {};
const adapterConfig = descriptor.adapterConfig || {};
switch (descriptor.adapter) {
  case "claude-code":
    for (const key of ["home", "settings", "configDir", "settingsArg"]) requireString(paths, key, "paths");
    requireString(provider, "baseUrl", "provider");
    requireString(auth, "env", "provider.auth");
    requireStringArray(models, "tiers", "models");
    for (const key of ["baseUrlEnv", "discoveryEnv", "tierModelEnvPrefix", "tierDisplayNameEnvPrefix", "autoCompactWindowEnv", "maxOutputTokensEnv"]) requireString(adapterConfig, key, "adapterConfig");
    if (!isObject(adapterConfig.outputReservation)) errors.push("adapterConfig.outputReservation must be an object");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "default", "adapterConfig.outputReservation");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "tokenizerHeadroom", "adapterConfig.outputReservation");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "minimumInput", "adapterConfig.outputReservation");
    break;
  case "codex-cli":
    for (const key of ["home", "settings", "codexHome", "config", "modelCatalog"]) requireString(paths, key, "paths");
    requireString(provider, "name", "provider");
    requireString(provider, "baseUrl", "provider");
    requireString(auth, "env", "provider.auth");
    requireString(models, "default", "models");
    if (!isObject(adapterConfig.outputReservation)) errors.push("adapterConfig.outputReservation must be an object");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "default", "adapterConfig.outputReservation");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "tokenizerHeadroom", "adapterConfig.outputReservation");
    requirePositiveInteger(adapterConfig.outputReservation || {}, "minimumInput", "adapterConfig.outputReservation");
    requireStringArray(adapterConfig, "subcommands", "adapterConfig");
    break;
  case "env-injector":
    requireString(paths, "home", "paths");
    requireString(models, "default", "models");
    if (!isObject(adapterConfig.env)) errors.push("adapterConfig.env must be an object");
    break;
  case "opencode-cli":
    for (const key of ["home", "config", "configDir"]) requireString(paths, key, "paths");
    requireString(provider, "name", "provider");
    requireString(provider, "baseUrl", "provider");
    requireString(auth, "env", "provider.auth");
    requireString(models, "default", "models");
    requireString(adapterConfig, "providerNpm", "adapterConfig");
    break;
}

if (errors.length) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
' "$descriptor" "$schema" || return 1

  adapter="$(ai_litellm_harness_json "$harness" adapter 2>/dev/null)" || return 1
  [[ -n "$adapter" ]]
}

ai_litellm_harness_cli_available() {
  local harness="$1"
  local command
  command="$(ai_litellm_harness_json "$harness" command 2>/dev/null)" || return 1
  command -v "$command" >/dev/null 2>&1 || {
    echo "Harness command not available for $harness: $command" >&2
    return 1
  }
}

ai_litellm_harness_template_json() {
  local harness="$1"
  local json_path="$2"
  local value
  value="$(ai_litellm_harness_json "$harness" "$json_path")" || return 1
  ai_litellm_template_value "$value"
}

ai_litellm_harness_env_assignments() {
  local harness="$1"
  local model_name="$2"
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1

  # Derive per-model token limits from the single source so descriptors can
  # reference {{limits.context}} / {{limits.output}} in adapterConfig.env.
  local model_limits ctx_limit out_limit output_budget reservation_output reservation_effective reservation_headroom reservation_minimum
  model_limits="$(ai_litellm_model_limits "$model_name" 2>/dev/null || true)"
  if [[ -n "$model_limits" ]]; then
    ctx_limit="$(print -r -- "$model_limits" | jq -r '.context // empty')"
    out_limit="$(print -r -- "$model_limits" | jq -r '.output // empty')"
  fi
  output_budget="$(ai_litellm_harness_output_budget "$harness" "$model_name" "$model_name" 2>/dev/null || true)"
  if [[ -n "$output_budget" ]]; then
    reservation_output="$(print -r -- "$output_budget" | jq -r '.reservation // empty')"
    reservation_effective="$(print -r -- "$output_budget" | jq -r '.effectiveInput // empty')"
    reservation_headroom="$(print -r -- "$output_budget" | jq -r '.tokenizerHeadroom // empty')"
    reservation_minimum="$(print -r -- "$output_budget" | jq -r '.minimumInput // empty')"
  fi

  node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const model = process.argv[2];
const baseUrl = process.argv[3];
const apiBaseUrl = process.argv[4];
const ctxLimit = process.argv[5] || "";
const outLimit = process.argv[6] || "";
const reservationOutput = process.argv[7] || "";
const reservationEffective = process.argv[8] || "";
const reservationHeadroom = process.argv[9] || "";
const reservationMinimum = process.argv[10] || "";
const paths = descriptor.paths || {};
const provider = descriptor.provider || {};
const providerBaseUrl = String(provider.baseUrl || "")
  .replaceAll("{{ai.baseUrl}}", baseUrl)
  .replaceAll("{{ai.apiBaseUrl}}", apiBaseUrl);
const replacements = new Map([
  ["{{ai.baseUrl}}", baseUrl],
  ["{{ai.apiBaseUrl}}", apiBaseUrl],
  ["{{model}}", model],
  ["{{provider.name}}", String(provider.name || "")],
  ["{{provider.baseUrl}}", providerBaseUrl],
  ["{{provider.basePath}}", String(provider.basePath || "")],
  ["{{limits.context}}", ctxLimit],
  ["{{limits.output}}", outLimit],
  ["{{reservation.output}}", reservationOutput],
  ["{{reservation.effectiveInput}}", reservationEffective],
  ["{{reservation.headroom}}", reservationHeadroom],
  ["{{reservation.minimumInput}}", reservationMinimum],
]);
for (const [key, value] of Object.entries(paths)) {
  replacements.set(`{{paths.${key}}}`, String(value));
}
const render = (value) => {
  let next = String(value);
  for (const [token, replacement] of replacements) {
    next = next.replaceAll(token, replacement);
  }
  return next;
};
for (const [key, value] of Object.entries(descriptor.adapterConfig?.env || {})) {
  const rendered = render(value);
  // Skip vars that resolve to empty (e.g. {{limits.context}} when the model has
  // no configured limit) so we never inject GOOSE_CONTEXT_LIMIT= and friends.
  if (rendered === "") continue;
  console.log(`${key}\t${rendered}`);
}
' "$descriptor" "$model_name" "$(ai_litellm_base_url)" "$(ai_litellm_api_base_url)" "$ctx_limit" "$out_limit" "$reservation_output" "$reservation_effective" "$reservation_headroom" "$reservation_minimum"
}

# Distinct os.environ/<VAR> references in the registry. Drives generic
# multi-provider secret injection (not just OpenRouter).
ai_litellm_config_env_refs() {
  [[ -f "$AI_LITELLM_CONFIG" ]] || return 1
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
seen = {}
walk = nil
walk = lambda do |o|
  case o
  when Hash then o.each_value { |v| walk.call(v) }
  when Array then o.each { |v| walk.call(v) }
  when String then seen[$1] = true if o =~ %r{\Aos\.environ/(.+)\z}
  end
end
walk.call(config)
seen.keys.sort.each { |k| puts k }
' "$AI_LITELLM_CONFIG"
}

# Resolve a provider secret env var without exporting it to the interactive shell.
# Order: private env file, then macOS Keychain. Keychain service defaults to the
# downcased dash form (OPENAI_API_KEY -> openai-api-key); override per var via
# settings.json secrets.<VAR>.{keychainService,keychainAccount}.
ai_litellm_resolve_secret_var() {
  local var="$1"
  [[ -n "$var" ]] || return 1
  ai_litellm_env_value "$var" 2>/dev/null && return 0
  local service account
  service="$(ai_litellm_json "secrets.$var.keychainService" 2>/dev/null || true)"
  account="$(ai_litellm_json "secrets.$var.keychainAccount" 2>/dev/null || printf '%s' "$USER")"
  if [[ -z "$service" ]]; then
    case "$var" in
      OPENROUTER_API_KEY) service="$OPENROUTER_KEYCHAIN_SERVICE" ;;
      LITELLM_MASTER_KEY) service="$LITELLM_MASTER_KEYCHAIN_SERVICE" ;;
      *) service="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')" ;;
    esac
  fi
  ai_litellm_keychain_value "$service" "$account" 2>/dev/null && return 0
  return 1
}

ai_litellm_harness_secret_value() {
  local source="$1"
  case "$source" in
    litellm-master-key)
      ai_litellm_master_key
      ;;
    openrouter-key)
      ai_litellm_openrouter_key
      ;;
    env:*)
      ai_litellm_resolve_secret_var "${source#env:}"
      ;;
    keychain:*)
      ai_litellm_keychain_value "${source#keychain:}" "$USER"
      ;;
    none|"")
      return 1
      ;;
    *)
      echo "Unsupported secret source: $source" >&2
      return 1
      ;;
  esac
}

ai_litellm_harness_exec_env() {
  local harness="$1"
  shift

  local -a env_args
  env_args=(env)

  local scrub
  for scrub in "${(@f)$(ai_litellm_harness_json_array "$harness" isolation.scrubEnv 2>/dev/null)}"; do
    [[ -n "$scrub" ]] && env_args+=(-u "$scrub")
  done

  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    env_args+=("$1")
    shift
  done

  "${env_args[@]}" "$@"
}

ai_litellm_ensure_claude_settings_file() {
  local settings_path="$1"
  [[ -n "$settings_path" ]] || {
    echo "Missing Claude settings path." >&2
    return 1
  }

  local settings_dir tmp
  settings_dir="${settings_path:h}"
  mkdir -p "$settings_dir" || return 1

  if [[ -f "$settings_path" ]]; then
    jq empty "$settings_path" >/dev/null || {
      echo "Invalid Claude LiteLLM settings JSON: $settings_path" >&2
      return 1
    }
    chmod 600 "$settings_path" 2>/dev/null || true
    return 0
  fi

  tmp="${settings_path}.$$"
  {
    print -r -- "{"
    print -r -- "}"
  } >| "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$settings_path"
}

ai_litellm_render_claude_settings() {
  local harness="${1:-claude}"
  local settings_path
  settings_path="$(ai_litellm_harness_json "$harness" paths.settingsArg)" || return 1
  ai_litellm_ensure_claude_settings_file "$settings_path"
}

ai_litellm_cli_arg_present() {
  local wanted="$1"
  shift

  local arg
  for arg in "$@"; do
    [[ "$arg" == "--" ]] && break
    [[ "$arg" == "$wanted" || "$arg" == "$wanted="* ]] && return 0
  done
  return 1
}

ai_litellm_harness_is_subcommand() {
  local harness="$1"
  local candidate="$2"
  [[ -n "$candidate" ]] || return 1
  ai_litellm_harness_json_array "$harness" adapterConfig.subcommands 2>/dev/null | grep -Fx -- "$candidate" >/dev/null
}

ai_litellm_harness_default_model() {
  local harness="$1"
  ai_litellm_harness_json "$harness" models.default 2>/dev/null || return 1
}

ai_litellm_harnesses() {
  local harness
  echo "ai-litellm harnesses"
  ai_litellm_harness_names | while IFS= read -r harness; do
    printf '  %s -> %s\n' "$harness" "$(ai_litellm_harness_json "$harness" adapter 2>/dev/null || printf 'unknown')"
  done
}

ai_litellm_harness_info() {
  local harness="$1"
  [[ -n "$harness" ]] || {
    ai_litellm_harnesses
    return 0
  }

  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || {
    echo "Unknown harness: $harness" >&2
    return 1
  }

  echo "Harness:   $harness"
  echo "Descriptor:$descriptor"
  echo "Adapter:   $(ai_litellm_harness_json "$harness" adapter 2>/dev/null || printf 'unknown')"
  echo "Command:   $(ai_litellm_harness_json "$harness" command 2>/dev/null || printf 'unknown')"
  echo "Settings:  $(ai_litellm_harness_json "$harness" paths.settings 2>/dev/null || printf 'none')"
  echo "Isolation: $(ai_litellm_harness_json "$harness" isolation.kind 2>/dev/null || printf 'unknown')"
  echo "Base URL:  $(ai_litellm_harness_json "$harness" provider.baseUrl 2>/dev/null | sed "s#{{ai.baseUrl}}#$(ai_litellm_base_url)#; s#{{ai.apiBaseUrl}}#$(ai_litellm_api_base_url)#" || printf 'n/a')"
  ai_litellm_harness_validate "$harness" >/dev/null 2>&1 && echo "Status:    ok" || echo "Status:    invalid"
  ai_litellm_harness_cli_available "$harness" >/dev/null 2>&1 && echo "CLI:       installed" || echo "CLI:       not installed"
}

ai_litellm_harness_parse_model_selection() {
  local harness="$1"
  shift

  AI_LITELLM_SELECTED_MODEL=""
  AI_LITELLM_SELECTED_MODEL_EXPLICIT=0
  AI_LITELLM_SELECTED_MODEL_CONSUMED=0

  local first_arg="${1:-}"
  if [[ -n "$first_arg" && "$first_arg" != -* ]] && ! ai_litellm_harness_is_subcommand "$harness" "$first_arg"; then
    if ai_litellm_model_exists "$first_arg"; then
      AI_LITELLM_SELECTED_MODEL="$first_arg"
      AI_LITELLM_SELECTED_MODEL_EXPLICIT=1
      AI_LITELLM_SELECTED_MODEL_CONSUMED=1
    fi
  fi

  if [[ -z "$AI_LITELLM_SELECTED_MODEL" ]]; then
    AI_LITELLM_SELECTED_MODEL="$(ai_litellm_harness_default_model "$harness")" || {
      echo "Missing default model for harness: $harness" >&2
      return 1
    }
  fi
  ai_litellm_model_exists "$AI_LITELLM_SELECTED_MODEL" || {
    echo "Unknown $harness LiteLLM model_name: $AI_LITELLM_SELECTED_MODEL" >&2
    return 1
  }
}

ai_litellm_launch_env_injector() {
  local harness="$1"
  shift

  local -a args env_assignments
  args=("$@")
  ai_litellm_harness_parse_model_selection "$harness" "${args[@]}" || return $?
  local model="$AI_LITELLM_SELECTED_MODEL"
  if (( AI_LITELLM_SELECTED_MODEL_CONSUMED )); then
    args=("${args[@]:1}")
  fi

  ai_litellm_model_runtime_ready "$model" || return $?
  ai_litellm_start >/dev/null || return $?

  local key value auth_env auth_source auth_secret isolation_env command
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && env_assignments+=("$key=$value")
  done < <(ai_litellm_harness_env_assignments "$harness" "$model")

  auth_env="$(ai_litellm_harness_json "$harness" provider.auth.env 2>/dev/null || true)"
  auth_source="$(ai_litellm_harness_json "$harness" provider.auth.source 2>/dev/null || true)"
  if [[ -n "$auth_env" && -n "$auth_source" && "$auth_source" != "none" ]]; then
    auth_secret="$(ai_litellm_harness_secret_value "$auth_source")" || return $?
    env_assignments+=("$auth_env=$auth_secret")
  fi

  isolation_env="$(ai_litellm_harness_json "$harness" isolation.env 2>/dev/null || true)"
  value="$(ai_litellm_harness_json "$harness" paths.home 2>/dev/null || true)"
  if [[ -n "$isolation_env" && -n "$value" ]]; then
    mkdir -p "$value"
    env_assignments+=("$isolation_env=$value")
  fi

  command="$(ai_litellm_harness_json "$harness" command)" || return 1
  ai_litellm_harness_exec_env "$harness" "${env_assignments[@]}" -- "$command" "${args[@]}"
}

ai_litellm_render_opencode_config() {
  local harness="$1"
  local descriptor config_path config_dir
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || return 1
  config_path="$(ai_litellm_harness_json "$harness" paths.config)" || return 1
  config_dir="$(ai_litellm_harness_json "$harness" paths.configDir)" || return 1
  mkdir -p "${config_path:h}" "$config_dir"

  ruby -rjson -ryaml -e '
descriptor = JSON.parse(File.read(ARGV[0]))
registry = (YAML.load_file(ARGV[1], aliases: true) rescue YAML.load_file(ARGV[1]))
api_base = ARGV[2]
config_path = ARGV[3]
provider = descriptor["provider"] || {}
adapter = descriptor["adapterConfig"] || {}
models_config = descriptor["models"] || {}
provider_name = provider["name"] || "litellm"
entries = Array(registry["model_list"])
routes = entries.map { |entry| entry["model_name"] }.compact
# Derive per-model context/output limits from the single source (model_info).
# OpenCode otherwise defaults to a 32000 max_tokens ceiling and truncates.
model_entries = entries.each_with_object({}) do |entry, acc|
  name = entry["model_name"]
  next unless name
  model = {"name" => name}
  mi = entry["model_info"] || {}
  if mi["max_input_tokens"]
    model["limit"] = {
      "context" => mi["max_input_tokens"],
      "output" => mi["max_output_tokens"] || 4096
    }
  end
  acc[name] = model
end
config = {
  "$schema" => "https://opencode.ai/config.json",
  "model" => "#{provider_name}/#{models_config["default"]}",
  "provider" => {
    provider_name => {
      "npm" => adapter["providerNpm"] || "@ai-sdk/openai-compatible",
      "name" => provider["displayName"] || provider_name,
      "options" => {
        "baseURL" => api_base,
        "apiKey" => "{env:#{provider.dig("auth", "env") || "LITELLM_MASTER_KEY"}}"
      },
      "models" => model_entries
    }
  }
}
if models_config["small"]
  config["small_model"] = "#{provider_name}/#{models_config["small"]}"
end
if adapter["disabledProviders"]
  config["disabled_providers"] = adapter["disabledProviders"]
end
if adapter["enabledProviders"]
  config["enabled_providers"] = adapter["enabledProviders"]
end
tmp = "#{config_path}.tmp.#{$$}"
File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0600) do |file|
  file.write(JSON.pretty_generate(config) + "\n")
end
File.rename(tmp, config_path)
' "$descriptor" "$AI_LITELLM_CONFIG" "$(ai_litellm_api_base_url)" "$config_path"
}

ai_litellm_launch_opencode() {
  local harness="$1"
  shift

  local -a args opencode_args env_assignments
  args=("$@")
  ai_litellm_harness_parse_model_selection "$harness" "${args[@]}" || return $?
  local model="$AI_LITELLM_SELECTED_MODEL"
  local explicit="$AI_LITELLM_SELECTED_MODEL_EXPLICIT"
  if (( AI_LITELLM_SELECTED_MODEL_CONSUMED )); then
    args=("${args[@]:1}")
  fi

  ai_litellm_model_runtime_ready "$model" || return $?
  ai_litellm_start >/dev/null || return $?
  ai_litellm_render_opencode_config "$harness" || return $?

  opencode_args=("${args[@]}")
  if [[ "$explicit" == "1" ]]; then
    local provider_name
    provider_name="$(ai_litellm_harness_json "$harness" provider.name 2>/dev/null || printf 'litellm')"
    if [[ "${opencode_args[1]:-}" == "run" ]]; then
      opencode_args=(run --model "$provider_name/$model" "${opencode_args[@]:1}")
    else
      opencode_args=(--model "$provider_name/$model" "${opencode_args[@]}")
    fi
  fi

  local harness_effort
  harness_effort="$(ai_litellm_harness_json "$harness" adapterConfig.reasoning.effort 2>/dev/null || true)"
  if [[ "${opencode_args[1]:-}" == "run" && -n "$harness_effort" && "$harness_effort" != "auto" && "$harness_effort" != "none" ]]; then
    if ! ai_litellm_cli_arg_present --variant "${opencode_args[@]}"; then
      opencode_args=(run --variant "$harness_effort" "${opencode_args[@]:1}")
    fi
  fi

  local auth_env auth_source auth_secret isolation_env config_env config_dir_env config_path config_dir command
  auth_env="$(ai_litellm_harness_json "$harness" provider.auth.env 2>/dev/null || true)"
  auth_source="$(ai_litellm_harness_json "$harness" provider.auth.source 2>/dev/null || true)"
  if [[ -n "$auth_env" && -n "$auth_source" && "$auth_source" != "none" ]]; then
    auth_secret="$(ai_litellm_harness_secret_value "$auth_source")" || return $?
    env_assignments+=("$auth_env=$auth_secret")
  fi

  local key value
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && env_assignments+=("$key=$value")
  done < <(ai_litellm_harness_env_assignments "$harness" "$model")

  isolation_env="$(ai_litellm_harness_json "$harness" isolation.env 2>/dev/null || printf 'OPENCODE_CONFIG')"
  config_path="$(ai_litellm_harness_json "$harness" paths.config)"
  config_dir="$(ai_litellm_harness_json "$harness" paths.configDir)"
  config_env="$(ai_litellm_harness_json "$harness" adapterConfig.configEnv 2>/dev/null || printf "$isolation_env")"
  config_dir_env="$(ai_litellm_harness_json "$harness" adapterConfig.configDirEnv 2>/dev/null || printf 'OPENCODE_CONFIG_DIR')"
  env_assignments+=("$config_env=$config_path" "$config_dir_env=$config_dir" "OPENCODE_DISABLE_AUTOUPDATE=true")

  local data_home cache_home state_home xdg_data_env xdg_cache_env xdg_state_env
  data_home="$(ai_litellm_harness_json "$harness" paths.dataHome 2>/dev/null || true)"
  cache_home="$(ai_litellm_harness_json "$harness" paths.cacheHome 2>/dev/null || true)"
  state_home="$(ai_litellm_harness_json "$harness" paths.stateHome 2>/dev/null || true)"
  xdg_data_env="$(ai_litellm_harness_json "$harness" adapterConfig.xdgDataEnv 2>/dev/null || printf 'XDG_DATA_HOME')"
  xdg_cache_env="$(ai_litellm_harness_json "$harness" adapterConfig.xdgCacheEnv 2>/dev/null || printf 'XDG_CACHE_HOME')"
  xdg_state_env="$(ai_litellm_harness_json "$harness" adapterConfig.xdgStateEnv 2>/dev/null || printf 'XDG_STATE_HOME')"
  [[ -n "$data_home" ]] && { mkdir -p "$data_home"; env_assignments+=("$xdg_data_env=$data_home"); }
  [[ -n "$cache_home" ]] && { mkdir -p "$cache_home"; env_assignments+=("$xdg_cache_env=$cache_home"); }
  [[ -n "$state_home" ]] && { mkdir -p "$state_home"; env_assignments+=("$xdg_state_env=$state_home"); }

  command="$(ai_litellm_harness_json "$harness" command)" || return 1
  ai_litellm_harness_exec_env "$harness" "${env_assignments[@]}" -- "$command" "${opencode_args[@]}"
}

ai_litellm_launch() {
  local harness="$1"
  [[ -n "$harness" ]] || {
    echo "Usage: ai-litellm launch <harness> [args...]" >&2
    return 1
  }
  shift

  ai_litellm_harness_validate "$harness" || return $?
  ai_litellm_harness_cli_available "$harness" || return $?
  local adapter
  adapter="$(ai_litellm_harness_json "$harness" adapter)" || return 1

  case "$adapter" in
    claude-code)
      CLAUDE_LITELLM_HARNESS="$harness" "$AI_LITELLM_BIN_DIR/claude-litellm" "$@"
      ;;
    codex-cli)
      CODEX_LITELLM_HARNESS="$harness" "$AI_LITELLM_BIN_DIR/codex-litellm" "$@"
      ;;
    env-injector)
      ai_litellm_launch_env_injector "$harness" "$@"
      ;;
    opencode-cli)
      ai_litellm_launch_opencode "$harness" "$@"
      ;;
    *)
      echo "Unsupported harness adapter: $adapter" >&2
      return 1
      ;;
  esac
}

ai_litellm_runtime_names() {
  [[ -f "$AI_LITELLM_SETTINGS" ]] || return 1
  node -e '
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const name of Object.keys(settings.runtimes || {})) console.log(name);
' "$AI_LITELLM_SETTINGS"
}

ai_litellm_runtime_field() {
  local runtime="$1"
  local field="$2"
  ai_litellm_json "runtimes.$runtime.$field"
}

ai_litellm_runtime_expected_models() {
  local runtime="$1"
  [[ -f "$AI_LITELLM_SETTINGS" ]] || return 1
  node -e '
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const runtime = settings.runtimes && settings.runtimes[process.argv[2]];
if (!runtime) process.exit(1);
for (const model of runtime.expectedModels || []) console.log(model);
' "$AI_LITELLM_SETTINGS" "$runtime"
}

ai_litellm_model_runtime() {
  local model_name="$1"
  local backend runtime prefix backend_model
  backend="$(ai_litellm_model_backend "$model_name" 2>/dev/null || true)"
  backend_model="${backend#openai/}"

  local -a runtimes
  runtimes=("${(@f)$(ai_litellm_runtime_names 2>/dev/null)}")
  for runtime in "${runtimes[@]}"; do
    prefix="$(ai_litellm_runtime_field "$runtime" modelPrefix 2>/dev/null || true)"
    [[ -n "$prefix" ]] || continue
    if [[ "$model_name" == "$prefix"* || "$backend_model" == "$prefix"* ]]; then
      printf '%s\n' "$runtime"
      return 0
    fi
  done

  return 1
}

# Supported runtime kinds. openai-compatible covers oMLX, exo, vLLM, and Ollama
# (via its /v1 endpoint). Add a new kind here AND a branch in the two adapters below.
ai_litellm_runtime_supported_kinds() {
  printf 'openai-compatible\n'
}

ai_litellm_runtime_kind() {
  ai_litellm_runtime_field "$1" kind 2>/dev/null || printf 'openai-compatible'
}

# Readiness adapter selection is driven by runtimes.<name>.kind. An unknown kind
# fails loudly here instead of silently using the wrong probe.
ai_litellm_runtime_reachable() {
  local runtime="$1"
  local kind api_base
  kind="$(ai_litellm_runtime_kind "$runtime")"
  api_base="$(ai_litellm_runtime_field "$runtime" apiBase 2>/dev/null)" || return 1
  case "$kind" in
    openai-compatible)
      curl --max-time 3 -fsS "$api_base/models" >/dev/null 2>&1
      ;;
    *)
      echo "Unsupported runtime kind '$kind' for runtime '$runtime'" >&2
      return 1
      ;;
  esac
}

ai_litellm_runtime_model_available() {
  local runtime="$1"
  local model_name="$2"
  local kind api_base
  kind="$(ai_litellm_runtime_kind "$runtime")"
  api_base="$(ai_litellm_runtime_field "$runtime" apiBase 2>/dev/null)" || return 1
  case "$kind" in
    openai-compatible)
      curl --max-time 3 -fsS "$api_base/models" 2>/dev/null | node -e '
const fs = require("fs");
const target = process.argv[1];
let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  process.exit(1);
}
const ids = (payload.data || []).map((model) => model.id || model.model || model.name).filter(Boolean);
process.exit(ids.includes(target) ? 0 : 1);
' "$model_name"
      ;;
    *)
      echo "Unsupported runtime kind '$kind' for runtime '$runtime'" >&2
      return 1
      ;;
  esac
}

# Validate one runtime block: required string fields, supported kind, non-empty
# expectedModels, and apiBase nested under baseUrl. Errors go to stderr.
ai_litellm_runtime_validate() {
  local runtime="$1"
  [[ -f "$AI_LITELLM_SETTINGS" ]] || return 1
  local supported
  supported="$(ai_litellm_runtime_supported_kinds | paste -sd, -)"
  node -e '
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const name = process.argv[2];
const supported = (process.argv[3] || "").split(",").filter(Boolean);
const rt = (settings.runtimes || {})[name];
if (!rt) { console.error(`runtime not found: ${name}`); process.exit(1); }
const errs = [];
for (const k of ["kind", "baseUrl", "apiBase", "modelPrefix"]) {
  if (typeof rt[k] !== "string" || rt[k].length === 0) errs.push(`${k} must be a non-empty string`);
}
if (rt.kind && !supported.includes(rt.kind)) errs.push(`unsupported kind: ${rt.kind} (supported: ${supported.join(", ")})`);
if (!Array.isArray(rt.expectedModels) || rt.expectedModels.length === 0) errs.push("expectedModels must be a non-empty array");
else if (rt.expectedModels.some((m) => typeof m !== "string" || !m.length)) errs.push("expectedModels entries must be strings");
if (typeof rt.apiBase === "string" && typeof rt.baseUrl === "string" && rt.baseUrl && !rt.apiBase.startsWith(rt.baseUrl)) {
  errs.push(`apiBase (${rt.apiBase}) should start with baseUrl (${rt.baseUrl})`);
}
if (errs.length) { console.error(`runtime ${name}: ${errs.join("; ")}`); process.exit(1); }
' "$AI_LITELLM_SETTINGS" "$runtime" "$supported"
}

# Cross-file consistency between settings.json runtimes and the litellm registry:
# expectedModels exist in the registry; prefix-matched models point at the runtime's
# apiBase; every local-* registry model belongs to some runtime prefix.
ai_litellm_runtime_consistency() {
  [[ -f "$AI_LITELLM_SETTINGS" && -f "$AI_LITELLM_CONFIG" ]] || return 0
  ruby -ryaml -rjson -e '
settings = JSON.parse(File.read(ARGV[0]))
config = (YAML.load_file(ARGV[1], aliases: true) rescue YAML.load_file(ARGV[1]))
models = Array(config["model_list"])
names = models.map { |e| e["model_name"] }.compact
errs = []
runtimes = settings["runtimes"] || {}
runtimes.each do |rt_name, rt|
  prefix = rt["modelPrefix"]
  api_base = rt["apiBase"]
  Array(rt["expectedModels"]).each do |m|
    errs << "#{rt_name}: expectedModel #{m} missing from registry" unless names.include?(m)
  end
  if prefix
    models.each do |e|
      n = e["model_name"]
      next unless n && n.start_with?(prefix)
      mb = e.dig("litellm_params", "api_base")
      errs << "#{n}: api_base #{mb.inspect} != runtime #{rt_name} apiBase #{api_base.inspect}" unless mb == api_base
    end
  end
end
local_prefixes = runtimes.values.map { |r| r["modelPrefix"] }.compact
names.select { |n| n.start_with?("local-") }.each do |n|
  errs << "#{n}: local model matches no runtime modelPrefix" unless local_prefixes.any? { |p| n.start_with?(p) }
end
if errs.any?
  errs.each { |e| warn e }
  exit 1
end
' "$AI_LITELLM_SETTINGS" "$AI_LITELLM_CONFIG"
}

# Endpoint/port collision detection across runtimes and against the proxy port.
ai_litellm_runtime_ports_ok() {
  [[ -f "$AI_LITELLM_SETTINGS" ]] || return 0
  local proxy_port
  proxy_port="$(ai_litellm_port 2>/dev/null || printf '4000')"
  node -e '
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const proxyPort = String(process.argv[2] || "");
const runtimes = settings.runtimes || {};
const seen = new Map();
const errs = [];
const hostport = (url) => {
  try { const u = new URL(url); return `${u.hostname}:${u.port || (u.protocol === "https:" ? "443" : "80")}`; }
  catch { return null; }
};
for (const [name, rt] of Object.entries(runtimes)) {
  const hp = hostport(rt.apiBase || rt.baseUrl || "");
  if (!hp) { errs.push(`${name}: cannot parse apiBase/baseUrl`); continue; }
  const port = hp.split(":").pop();
  if (port === proxyPort) errs.push(`${name}: port ${port} collides with LiteLLM proxy port`);
  if (seen.has(hp)) errs.push(`${name}: endpoint ${hp} collides with runtime ${seen.get(hp)}`);
  else seen.set(hp, name);
}
if (errs.length) { errs.forEach((e) => console.error(e)); process.exit(1); }
' "$AI_LITELLM_SETTINGS" "$proxy_port"
}

ai_litellm_runtime_status_one() {
  local runtime="$1"
  local base_url api_base models_dir start_command stop_command managed_by
  base_url="$(ai_litellm_runtime_field "$runtime" baseUrl 2>/dev/null || true)"
  api_base="$(ai_litellm_runtime_field "$runtime" apiBase 2>/dev/null || true)"
  models_dir="$(ai_litellm_runtime_field "$runtime" modelsDir 2>/dev/null || true)"
  start_command="$(ai_litellm_runtime_field "$runtime" startCommand 2>/dev/null || true)"
  stop_command="$(ai_litellm_runtime_field "$runtime" stopCommand 2>/dev/null || true)"
  managed_by="$(ai_litellm_runtime_field "$runtime" managedBy 2>/dev/null || true)"

  echo "Runtime:   $runtime"
  echo "Base URL:  ${base_url:-unknown}"
  echo "API base:  ${api_base:-unknown}"
  echo "Model dir: ${models_dir:-unknown}"
  echo "Start:     ${start_command:-manual}"
  echo "Stop:      ${stop_command:-manual}"
  echo "Managed:   ${managed_by:-user}"
  if ai_litellm_runtime_reachable "$runtime"; then
    echo "Health:    ok"
  else
    echo "Health:    not reachable"
  fi

  local model
  echo "Expected models:"
  ai_litellm_runtime_expected_models "$runtime" 2>/dev/null | while IFS= read -r model; do
    if ai_litellm_runtime_model_available "$runtime" "$model"; then
      printf '  ok   %s\n' "$model"
    else
      printf '  fail %s\n' "$model"
    fi
  done
}

ai_litellm_runtime_status() {
  local runtime="$1"
  if [[ -n "$runtime" ]]; then
    ai_litellm_runtime_status_one "$runtime"
    return $?
  fi

  local -a runtimes
  runtimes=("${(@f)$(ai_litellm_runtime_names 2>/dev/null)}")
  if (( ${#runtimes[@]} == 0 )); then
    echo "No local runtimes configured"
    return 0
  fi

  local item
  for item in "${runtimes[@]}"; do
    ai_litellm_runtime_status_one "$item"
    echo
  done
}

ai_litellm_model_runtime_ready() {
  local model_name="$1"
  local runtime
  runtime="$(ai_litellm_model_runtime "$model_name" 2>/dev/null)" || return 0

  if ai_litellm_runtime_model_available "$runtime" "$model_name"; then
    return 0
  fi

  local api_base start_command models_dir
  api_base="$(ai_litellm_runtime_field "$runtime" apiBase 2>/dev/null || printf 'unknown')"
  start_command="$(ai_litellm_runtime_field "$runtime" startCommand 2>/dev/null || printf 'manual start')"
  models_dir="$(ai_litellm_runtime_field "$runtime" modelsDir 2>/dev/null || printf 'unknown')"

  echo "Runtime '$runtime' is not ready for LiteLLM model '$model_name'." >&2
  echo "Endpoint: $api_base" >&2
  echo "Start it manually: $start_command" >&2
  echo "Expected model directory: $models_dir/$model_name" >&2
  echo "No fallback was attempted." >&2
  return 1
}

ai_litellm_pid_from_file() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(<"$pid_file")"
  ai_litellm_pid_is_litellm "$pid" || return 1
  printf '%s\n' "$pid"
}

ai_litellm_pid_is_litellm() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local command_line
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *litellm* ]]
}

ai_litellm_active_pid_file() {
  local pid_file
  for pid_file in "$AI_LITELLM_PID_FILE" "$AI_LITELLM_LEGACY_PID_FILE" "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE"; do
    ai_litellm_pid_from_file "$pid_file" >/dev/null 2>&1 || continue
    printf '%s\n' "$pid_file"
    return 0
  done
  return 1
}

ai_litellm_active_pid() {
  local pid_file
  pid_file="$(ai_litellm_active_pid_file)" || return 1
  ai_litellm_pid_from_file "$pid_file"
}

ai_litellm_pid_running() {
  ai_litellm_active_pid >/dev/null 2>&1
}

ai_litellm_health() {
  local master_key
  master_key="$(ai_litellm_master_key 2>/dev/null)" || true

  if [[ -n "$master_key" ]]; then
    ai_litellm_curl_auth "$master_key" --max-time 3 -fsS "$(ai_litellm_base_url)/health/readiness" >/dev/null 2>&1
  else
    curl --max-time 3 -fsS "$(ai_litellm_base_url)/health/readiness" >/dev/null 2>&1
  fi
}

ai_litellm_config_hash() {
  [[ -f "$AI_LITELLM_CONFIG" ]] || return 1
  shasum -a 256 "$AI_LITELLM_CONFIG" | awk '{print $1}'
}

ai_litellm_record_proxy_config_state() {
  mkdir -p "$AI_LITELLM_HOME"
  ai_litellm_config_hash > "$AI_LITELLM_CONFIG_HASH_FILE" 2>/dev/null || true
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$AI_LITELLM_STARTED_AT_FILE"
}

ai_litellm_proxy_config_current() {
  [[ -f "$AI_LITELLM_CONFIG_HASH_FILE" ]] || return 2
  local current recorded
  current="$(ai_litellm_config_hash 2>/dev/null)" || return 1
  recorded="$(<"$AI_LITELLM_CONFIG_HASH_FILE")"
  [[ -n "$recorded" && "$current" == "$recorded" ]]
}

ai_litellm_proxy_model_names() {
  local master_key
  master_key="$(ai_litellm_master_key 2>/dev/null)" || return 1
  ai_litellm_curl_auth "$master_key" --max-time 5 -fsS "$(ai_litellm_base_url)/model/info" \
    | jq -r '.data[].model_name'
}

ai_litellm_proxy_registry_matches_file() {
  ai_litellm_health || return 0
  diff -u <(ai_litellm_model_names | sort -u) <(ai_litellm_proxy_model_names | sort -u) >/dev/null
}

ai_litellm_reachable_proxy_current() {
  ai_litellm_proxy_config_current || return 1
  ai_litellm_proxy_registry_matches_file || return 1
}

ai_litellm_lock_stale() {
  [[ -d "$AI_LITELLM_LOCK_DIR" ]] || return 1
  local lock_pid=""
  [[ -f "$AI_LITELLM_LOCK_DIR/pid" ]] && lock_pid="$(<"$AI_LITELLM_LOCK_DIR/pid")"
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    local age=0
    if [[ -f "$AI_LITELLM_LOCK_DIR/started_at" ]]; then
      age="$(perl -e 'print int(time - (stat($ARGV[0]))[9])' "$AI_LITELLM_LOCK_DIR/started_at" 2>/dev/null || printf '0')"
    fi
    if (( ${age:-0} > ${AI_LITELLM_LOCK_MAX_AGE_SECONDS:-300} )) && ! ai_litellm_health; then
      return 0
    fi
    return 1
  fi
  return 0
}

ai_litellm_clear_lock() {
  [[ -d "$AI_LITELLM_LOCK_DIR" ]] || return 0
  rm -f "$AI_LITELLM_LOCK_DIR/pid" "$AI_LITELLM_LOCK_DIR/started_at" 2>/dev/null || true
  rmdir "$AI_LITELLM_LOCK_DIR" 2>/dev/null || true
}

ai_litellm_acquire_lock() {
  local lock_wait
  mkdir -p "$AI_LITELLM_HOME"
  for lock_wait in {1..50}; do
    if mkdir "$AI_LITELLM_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$AI_LITELLM_LOCK_DIR/pid"
      date -u '+%Y-%m-%dT%H:%M:%SZ' > "$AI_LITELLM_LOCK_DIR/started_at"
      return 0
    fi

    if ai_litellm_health; then
      return 2
    fi

    if ai_litellm_lock_stale; then
      ai_litellm_clear_lock
      continue
    fi

    sleep 0.1
  done

  return 1
}

ai_litellm_start() {
  local master_key openrouter_key
  master_key="$(ai_litellm_master_key 2>/dev/null)" || true
  if [[ -z "$master_key" ]]; then
    echo "Missing LiteLLM master key. Store it in Keychain service $LITELLM_MASTER_KEYCHAIN_SERVICE or $AI_LITELLM_ENV." >&2
    return 1
  fi

  openrouter_key="$(ai_litellm_openrouter_key 2>/dev/null)" || true
  if grep -q 'os\.environ/OPENROUTER_API_KEY' "$AI_LITELLM_CONFIG" && [[ -z "$openrouter_key" ]]; then
    echo "Missing OpenRouter API key. Store it in Keychain service $OPENROUTER_KEYCHAIN_SERVICE or $AI_LITELLM_ENV." >&2
    return 1
  fi

  mkdir -p "$AI_LITELLM_HOME"
  chmod 700 "$AI_LITELLM_HOME" 2>/dev/null || true
  [[ -f "$AI_LITELLM_LOG_FILE" ]] && chmod 600 "$AI_LITELLM_LOG_FILE" 2>/dev/null || true

  if ai_litellm_health; then
    if ! ai_litellm_reachable_proxy_current; then
      echo "LiteLLM is reachable at $(ai_litellm_base_url), but it has not loaded the current $AI_LITELLM_CONFIG routes." >&2
      echo "Run 'ai-litellm sync' before launching harnesses." >&2
      return 1
    fi
    echo "LiteLLM is already reachable at $(ai_litellm_base_url)"
    return 0
  fi

  local lock_result
  ai_litellm_acquire_lock
  lock_result=$?
  if (( lock_result == 2 )); then
    if ! ai_litellm_reachable_proxy_current; then
      echo "LiteLLM is reachable at $(ai_litellm_base_url), but it has not loaded the current $AI_LITELLM_CONFIG routes." >&2
      echo "Run 'ai-litellm sync' before launching harnesses." >&2
      return 1
    fi
    echo "LiteLLM is already reachable at $(ai_litellm_base_url)"
    return 0
  fi
  if (( lock_result != 0 )); then
    echo "Timed out waiting for LiteLLM start lock: $AI_LITELLM_LOCK_DIR" >&2
    return 1
  fi

  if ai_litellm_health; then
    ai_litellm_clear_lock
    if ! ai_litellm_reachable_proxy_current; then
      echo "LiteLLM is reachable at $(ai_litellm_base_url), but it has not loaded the current $AI_LITELLM_CONFIG routes." >&2
      echo "Run 'ai-litellm sync' before launching harnesses." >&2
      return 1
    fi
    echo "LiteLLM is already reachable at $(ai_litellm_base_url)"
    return 0
  fi

  if ai_litellm_pid_running; then
    echo "LiteLLM pid file exists, but health check failed: $(ai_litellm_active_pid)"
    echo "Log: $(ai_litellm_active_log_file)"
    ai_litellm_clear_lock
    return 1
  fi

  rm -f "$AI_LITELLM_PID_FILE" "$AI_LITELLM_LEGACY_PID_FILE" "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE"
  : > "$AI_LITELLM_LOG_FILE"
  chmod 600 "$AI_LITELLM_LOG_FILE" 2>/dev/null || true

  # Resolve every other os.environ/<VAR> the registry references (OpenAI, Anthropic,
  # Gemini, ... beyond OpenRouter) from Keychain/env-file and inject them into the
  # proxy subprocess only. Never exported to the interactive shell.
  local -a extra_env
  local _ref _val
  for _ref in ${(f)"$(ai_litellm_config_env_refs 2>/dev/null)"}; do
    case "$_ref" in
      OPENROUTER_API_KEY|LITELLM_MASTER_KEY) continue ;;
    esac
    _val="$(ai_litellm_resolve_secret_var "$_ref" 2>/dev/null || true)"
    if [[ -n "$_val" ]]; then
      extra_env+=("$_ref=$_val")
    else
      echo "warn: registry references os.environ/$_ref but it is not in Keychain/env-file; routes needing it will fail until you store it." >&2
    fi
  done

  local pid
  pid="$(
    OPENROUTER_API_KEY="$openrouter_key" \
    LITELLM_MASTER_KEY="$master_key" \
    AI_LITELLM_HOST="$(ai_litellm_host)" \
    AI_LITELLM_PORT="$(ai_litellm_port)" \
    env "${extra_env[@]}" python3 - <<'PY'
import os
import subprocess
import sys

cmd = [
    "litellm",
    "--config",
    os.environ["AI_LITELLM_CONFIG"],
    "--host",
    os.environ["AI_LITELLM_HOST"],
    "--port",
    os.environ["AI_LITELLM_PORT"],
]

try:
    log = open(os.environ["AI_LITELLM_LOG_FILE"], "ab", buffering=0)
    process = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
except Exception as exc:
    print(f"Failed to start LiteLLM: {exc}", file=sys.stderr)
    raise SystemExit(1)

print(process.pid)
PY
  )" || {
    echo "Failed to start LiteLLM. Log: $AI_LITELLM_LOG_FILE"
    ai_litellm_clear_lock
    return 1
  }
  printf '%s\n' "$pid" > "$AI_LITELLM_PID_FILE"

  local i
  for i in {1..30}; do
    if ai_litellm_health; then
      ai_litellm_record_proxy_config_state
      echo "LiteLLM started at $(ai_litellm_base_url) (pid $pid)"
      ai_litellm_clear_lock
      return 0
    fi
    sleep 0.2
  done

  echo "LiteLLM did not become healthy. Log: $AI_LITELLM_LOG_FILE"
  ai_litellm_clear_lock
  return 1
}

ai_litellm_stop() {
  echo "Stopping shared LiteLLM proxy; active claude-litellm and codex-litellm sessions may fail." >&2

  local pid_file pid
  pid_file="$(ai_litellm_active_pid_file 2>/dev/null)" || {
    rm -f "$AI_LITELLM_PID_FILE" "$AI_LITELLM_LEGACY_PID_FILE" "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE"
    echo "No ai-litellm managed LiteLLM process is running"
    return 0
  }
  pid="$(ai_litellm_pid_from_file "$pid_file")" || {
    rm -f "$AI_LITELLM_PID_FILE" "$AI_LITELLM_LEGACY_PID_FILE" "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE"
    echo "No ai-litellm managed LiteLLM process is running"
    return 0
  }

  kill "$pid" 2>/dev/null || true
  rm -f "$AI_LITELLM_PID_FILE" "$AI_LITELLM_LEGACY_PID_FILE" "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE"
  rm -f "$AI_LITELLM_CONFIG_HASH_FILE" "$AI_LITELLM_STARTED_AT_FILE"
  ai_litellm_clear_lock
  echo "LiteLLM stopped (pid $pid)"
}

ai_litellm_restart() {
  ai_litellm_stop || return $?
  ai_litellm_start
}

ai_litellm_active_log_file() {
  local pid_file
  pid_file="$(ai_litellm_active_pid_file 2>/dev/null)" || {
    printf '%s\n' "$AI_LITELLM_LOG_FILE"
    return 0
  }
  if [[ "$pid_file" == "$AI_LITELLM_LEGACY_PID_FILE" ]]; then
    printf '%s\n' "$AI_LITELLM_LEGACY_LOG_FILE"
  elif [[ "$pid_file" == "$AI_LITELLM_LEGACY_CLAUDE_PID_FILE" ]]; then
    printf '%s\n' "$AI_LITELLM_LEGACY_CLAUDE_LOG_FILE"
  else
    printf '%s\n' "$AI_LITELLM_LOG_FILE"
  fi
}

ai_litellm_status() {
  echo "Config:   $AI_LITELLM_CONFIG"
  echo "Settings: $AI_LITELLM_SETTINGS"
  echo "Base URL: $(ai_litellm_base_url)"
  if ai_litellm_pid_running; then
    echo "PID:      $(ai_litellm_active_pid)"
    echo "PID file: $(ai_litellm_active_pid_file)"
  else
    echo "PID:      none"
  fi
  if ai_litellm_health; then
    echo "Health:   ok"
  else
    echo "Health:   not reachable"
  fi
  if ai_litellm_pid_running; then
    local config_state
    ai_litellm_proxy_config_current
    config_state=$?
    case "$config_state" in
      0)
        echo "Config:   current in running proxy"
        ;;
      2)
        echo "Config:   unknown in running proxy; restart once to record hash"
        ;;
      *)
        echo "Config:   stale in running proxy; restart required"
        ;;
    esac
  fi
  if [[ -d "$AI_LITELLM_LOCK_DIR" ]]; then
    echo "Lock:     $AI_LITELLM_LOCK_DIR"
  else
    echo "Lock:     none"
  fi
  echo "Log:      $(ai_litellm_active_log_file)"
}

ai_litellm_list() {
  echo "LiteLLM model_name entries:"
  ai_litellm_model_names | sed 's/^/  /'
}

ai_litellm_route_info() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "Missing curl or jq." >&2
    return 1
  fi

  local master_key
  master_key="$(ai_litellm_master_key 2>/dev/null)" || true
  if [[ -z "$master_key" ]]; then
    echo "Missing LiteLLM master key." >&2
    return 1
  fi

  local model_filter="$1"
  local payload
  if ! payload="$(ai_litellm_curl_auth "$master_key" --max-time 5 -fsS "$(ai_litellm_base_url)/model/info")"; then
    echo "LiteLLM route metadata unavailable at $(ai_litellm_base_url)/model/info; is the proxy running?" >&2
    return 1
  fi

  local jq_filter
  if [[ -n "$model_filter" ]]; then
    jq_filter='.data[] | select(.model_name == $model) | [.model_name, .litellm_params.model, .model_info.litellm_provider] | @tsv'
  else
    jq_filter='.data[] | [.model_name, .litellm_params.model, .model_info.litellm_provider] | @tsv'
  fi

  print -r -- "$payload" \
    | jq -r --arg model "$model_filter" "$jq_filter" \
    | awk 'BEGIN { printf "%-18s %-48s %s\n", "model_name", "provider_model", "provider" } { printf "%-18s %-48s %s\n", $1, $2, $3 }'
}

ai_litellm_probe_route() {
  local model_name="$1"
  [[ -n "$model_name" ]] || {
    echo "Usage: ai-litellm probe-route <model_name> [model_name...]" >&2
    return 1
  }

  ai_litellm_model_exists "$model_name" || {
    echo "fail $model_name: not present in $AI_LITELLM_CONFIG" >&2
    return 1
  }
  ai_litellm_model_runtime_ready "$model_name" || return 1

  local master_key payload
  master_key="$(ai_litellm_master_key 2>/dev/null)" || {
    echo "Missing LiteLLM master key." >&2
    return 1
  }
  payload="$(jq -nc --arg model "$model_name" '{
    model: $model,
    messages: [{role: "user", content: "Reply with exactly OK"}],
    max_tokens: 128,
    temperature: 0
  }')"

  if ai_litellm_curl_auth "$master_key" --max-time 90 -fsS \
    -H "Content-Type: application/json" \
    "$(ai_litellm_api_base_url)/chat/completions" \
    -d "$payload" \
    | jq -e '.choices[0].message.content // .choices[0].text // empty' >/dev/null; then
    echo "ok   route probe: $model_name"
    return 0
  fi

  echo "fail route probe: $model_name" >&2
  return 1
}

ai_litellm_probe_routes() {
  local failed=0
  if (( $# == 0 )); then
    echo "Usage: ai-litellm probe-route <model_name> [model_name...]" >&2
    return 1
  fi

  local model_name
  for model_name in "$@"; do
    ai_litellm_probe_route "$model_name" || failed=1
  done
  return $failed
}

openrouter-key-status() {
  if [[ -n "$OPENROUTER_API_KEY" ]]; then
    echo "OPENROUTER_API_KEY: set in current environment"
    return 0
  fi

  if ai_litellm_env_value OPENROUTER_API_KEY >/dev/null 2>&1; then
    echo "OPENROUTER_API_KEY: available in env file"
    return 0
  fi

  if ai_litellm_keychain_value "$OPENROUTER_KEYCHAIN_SERVICE" "$OPENROUTER_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    echo "OPENROUTER_API_KEY: available in macOS Keychain"
    echo "Keychain service: $OPENROUTER_KEYCHAIN_SERVICE"
    return 0
  fi

  echo "OPENROUTER_API_KEY: not found"
  echo "Expected Keychain service: $OPENROUTER_KEYCHAIN_SERVICE"
  return 1
}

litellm-master-key-status() {
  if [[ -n "$LITELLM_MASTER_KEY" ]]; then
    echo "LITELLM_MASTER_KEY: set in current environment"
    return 0
  fi

  if ai_litellm_env_value LITELLM_MASTER_KEY >/dev/null 2>&1; then
    echo "LITELLM_MASTER_KEY: available in env file"
    return 0
  fi

  if ai_litellm_keychain_value "$LITELLM_MASTER_KEYCHAIN_SERVICE" "$LITELLM_MASTER_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    echo "LITELLM_MASTER_KEY: available in macOS Keychain"
    echo "Keychain service: $LITELLM_MASTER_KEYCHAIN_SERVICE"
    return 0
  fi

  echo "LITELLM_MASTER_KEY: not found"
  echo "Expected Keychain service: $LITELLM_MASTER_KEYCHAIN_SERVICE"
  return 1
}

openrouter-key-load() {
  echo "OPENROUTER_API_KEY shell export is intentionally disabled; wrappers inject it only into subprocesses." >&2
  return 1
}

litellm-master-key-load() {
  echo "LITELLM_MASTER_KEY shell export is intentionally disabled; wrappers inject it only into subprocesses." >&2
  return 1
}

ai_litellm_key_status() {
  openrouter-key-status
  litellm-master-key-status
}

ai_litellm_logs() {
  local lines="${1:-$(ai_litellm_json logs.tail 2>/dev/null || printf '120')}"
  local log_file
  log_file="$(ai_litellm_active_log_file)"
  [[ -f "$log_file" ]] || {
    echo "No LiteLLM log file found: $log_file" >&2
    return 1
  }
  tail -n "$lines" "$log_file"
}

ai_litellm_doctor_check() {
  local label="$1"
  shift
  if "$@"; then
    echo "ok   $label"
    return 0
  fi
  echo "fail $label"
  return 1
}

ai_litellm_quiet() {
  "$@" >/dev/null 2>&1
}

ai_litellm_doctor_warn_env() {
  [[ -n "$OPENROUTER_API_KEY" ]] && echo "warn OPENROUTER_API_KEY is set in current environment"
  [[ -n "$LITELLM_MASTER_KEY" ]] && echo "warn LITELLM_MASTER_KEY is set in current environment"
}

ai_litellm_doctor_shortcuts() {
  local settings="${CODEX_LITELLM_SETTINGS:-$AI_LITELLM_CONFIG_HOME/codex-litellm/settings.json}"
  [[ -f "$settings" ]] || return 0
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor codex)" || return 1
  node -e '
const fs = require("fs");
const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const descriptor = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const aliases = Object.keys(settings.aliases || {});
const subcommands = new Set(descriptor.adapterConfig?.subcommands || []);
const conflicts = aliases.filter((alias) => subcommands.has(alias));
if (conflicts.length) {
  console.error(`conflicting Codex shortcuts: ${conflicts.join(", ")}`);
  process.exit(1);
}
' "$settings" "$descriptor"
}

ai_litellm_doctor_harnesses() {
  local failed=0
  local harness
  for harness in "${(@f)$(ai_litellm_harness_names)}"; do
    ai_litellm_doctor_check "harness descriptor valid: $harness" ai_litellm_harness_validate "$harness" || failed=1
    if ! ai_litellm_harness_cli_available "$harness" >/dev/null 2>&1; then
      echo "warn harness CLI not installed: $harness ($(ai_litellm_harness_json "$harness" command 2>/dev/null || printf 'unknown'))"
    fi
  done
  return $failed
}

ai_litellm_doctor_codex_config_base_url() {
  local config
  config="$(ai_litellm_harness_json codex paths.config 2>/dev/null)" || return 0
  [[ -f "$config" ]] || return 0
  local configured
  configured="$(awk -F'"' '/^[[:space:]]*base_url[[:space:]]*=/ { print $2; exit }' "$config" 2>/dev/null)"
  [[ "$configured" == "$(ai_litellm_api_base_url)" ]]
}

ai_litellm_doctor_opencode_config_base_url() {
  local config provider_name
  config="$(ai_litellm_harness_json opencode paths.config 2>/dev/null)" || return 0
  [[ -f "$config" ]] || return 0
  provider_name="$(ai_litellm_harness_json opencode provider.name 2>/dev/null || printf 'litellm')"
  jq -e --arg provider "$provider_name" --arg api_base "$(ai_litellm_api_base_url)" \
    '.provider[$provider].options.baseURL == $api_base' "$config" >/dev/null
}

ai_litellm_doctor_limit_sync() {
  local raw_map codex_map
  raw_map="$(ai_litellm_limits_map 2>/dev/null)" || return 0
  [[ -n "$raw_map" && "$raw_map" != "{}" ]] || return 0
  codex_map="$(ai_litellm_codex_catalog_context_map codex 2>/dev/null)" || codex_map="$raw_map"
  [[ -n "$codex_map" && "$codex_map" != "{}" ]] || codex_map="$raw_map"
  local failed=0 mismatch

  local catalog
  catalog="$(ai_litellm_harness_json codex paths.modelCatalog 2>/dev/null || true)"
  [[ -n "$catalog" ]] || catalog="$AI_LITELLM_STATE_HOME/codex-litellm/model-catalog.json"
  if [[ -f "$catalog" ]]; then
    mismatch="$(node -e '
const fs = require("fs");
const map = JSON.parse(process.argv[1]);
const cat = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const bad = [];
for (const m of cat.models || []) {
  if (map[m.slug] != null && m.context_window !== map[m.slug]) {
    bad.push(`${m.slug}(${m.context_window}!=${map[m.slug]})`);
  }
}
if (bad.length) console.log(bad.join(" "));
' "$codex_map" "$catalog" 2>/dev/null)"
    if [[ -n "$mismatch" ]]; then
      echo "stale Codex catalog safe context_window: $mismatch (run: ai-litellm sync)" >&2
      failed=1
    fi
  fi

  local opencode_config provider_name
  opencode_config="$(ai_litellm_harness_json opencode paths.config 2>/dev/null || true)"
  if [[ -n "$opencode_config" && -f "$opencode_config" ]]; then
    provider_name="$(ai_litellm_harness_json opencode provider.name 2>/dev/null || printf 'litellm')"
    mismatch="$(node -e '
const fs = require("fs");
const map = JSON.parse(process.argv[1]);
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const prov = process.argv[3];
const models = (cfg.provider && cfg.provider[prov] && cfg.provider[prov].models) || {};
const bad = [];
for (const [name, m] of Object.entries(models)) {
  const want = map[name];
  if (want == null) continue;
  const have = m.limit && m.limit.context;
  if (have !== want) bad.push(`${name}(${have}!=${want})`);
}
if (bad.length) console.log(bad.join(" "));
' "$raw_map" "$opencode_config" "$provider_name" 2>/dev/null)"
    if [[ -n "$mismatch" ]]; then
      echo "stale OpenCode config context: $mismatch (run: ai-litellm sync)" >&2
      failed=1
    fi
  fi

  return $failed
}

ai_litellm_doctor_reasoning_sync() {
  local descriptor config
  descriptor="$(ai_litellm_harness_descriptor codex 2>/dev/null)" || return 0
  config="$(ai_litellm_harness_json codex paths.config 2>/dev/null || true)"
  [[ -n "$config" && -f "$config" ]] || return 0

  node -e '
const fs = require("fs");
const descriptor = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const config = fs.readFileSync(process.argv[2], "utf8");
const adapter = descriptor.adapterConfig || {};
const expected = String(adapter.modelReasoningEffort || "xhigh");
const metadataEffort = adapter.reasoning && adapter.reasoning.effort;
if (metadataEffort && String(metadataEffort) !== expected) {
  console.error(`Codex descriptor reasoning drift: reasoning.effort=${metadataEffort} modelReasoningEffort=${expected}`);
  process.exit(1);
}
const match = config.match(/^model_reasoning_effort\s*=\s*"([^"]+)"/m);
const actual = match && match[1];
if (actual !== expected) {
  console.error(`stale Codex reasoning config: model_reasoning_effort=${actual || "<missing>"} expected=${expected} (run: ai-litellm sync)`);
  process.exit(1);
}
' "$descriptor" "$config"
}

ai_litellm_doctor_reasoning_capability_truth() {
  local litellm_python
  litellm_python="$(ai_litellm_litellm_python 2>/dev/null)" || {
    echo "warn reasoning capability: LiteLLM Python runtime not available"
    return 0
  }

  "$litellm_python" - "$AI_LITELLM_CONFIG" "$AI_LITELLM_REASONING_OBS_FILE" <<'PY'
import json
import sys

import yaml

try:
    import litellm
except Exception as exc:
    print(f"warn reasoning capability: cannot import litellm ({exc})")
    raise SystemExit(0)

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    config = yaml.safe_load(fh) or {}
try:
    with open(sys.argv[2], "r", encoding="utf-8") as fh:
        observations = json.load(fh)
except Exception:
    observations = {}

drop_params = bool((config.get("litellm_settings") or {}).get("drop_params"))
observed_backends = {
    obs.get("provider_model")
    for obs in (observations.get("models") or {}).values()
    if obs.get("status") == "observed" and obs.get("provider_model")
}
seen = set()
for entry in config.get("model_list") or []:
    name = entry.get("model_name")
    backend = (entry.get("litellm_params") or {}).get("model")
    if not name or not backend:
        continue
    if (entry.get("model_info") or {}).get("supports_reasoning") is not True:
        continue
    key = (backend, drop_params)
    if key in seen:
        continue
    seen.add(key)
    if backend in observed_backends:
        continue
    try:
        params = litellm.get_supported_openai_params(model=backend) or []
        supported = bool(litellm.supports_reasoning(model=backend)) or any(
            p in params for p in ("reasoning_effort", "reasoning", "thinking")
        )
    except Exception:
        supported = False
    if not supported:
        mode = "dropped" if drop_params else "rejected"
        print(f"warn declared reasoning may be {mode} by local LiteLLM for backend {backend}")
PY
}

ai_litellm_render_codex_config() {
  local shell="$AI_LITELLM_CONFIG_HOME/codex-litellm/shell.zsh"
  [[ -f "$shell" ]] || return 0
  (
    source "$shell" >/dev/null 2>&1 || exit 1
    codex-litellm-render-config
  )
}

# Regenerate every derived artifact from the single source and reload the proxy.
# After editing a token limit in litellm_config.yaml, this is the one command to run.
ai_litellm_sync() {
  local failed=0 dry_run=0 restart=1 codex_command codex_wrapper arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        dry_run=1
        restart=0
        ;;
      --no-restart)
        restart=0
        ;;
      -h|--help)
        echo "Usage: ai-litellm sync [--dry-run] [--no-restart]"
        echo "  --dry-run     print derived-artifact actions without writing or restarting"
        echo "  --no-restart  regenerate derived artifacts without restarting the shared proxy"
        return 0
        ;;
      *)
        echo "Unknown sync option: $arg" >&2
        return 1
        ;;
    esac
  done

  echo "ai-litellm sync"
  (( dry_run )) && echo "- dry-run: no files will be changed and proxy will not restart"

  codex_command="$(ai_litellm_harness_json codex command 2>/dev/null || printf 'codex')"
  codex_wrapper="$AI_LITELLM_BIN_DIR/codex-litellm"
  if [[ -x "$codex_wrapper" ]]; then
    if [[ -n "$codex_command" ]] && command -v "$codex_command" >/dev/null 2>&1; then
      echo "- codex catalog"
      if (( ! dry_run )); then
        "$codex_wrapper" --refresh-catalog || failed=1
      fi
    else
      echo "- codex catalog skipped (${codex_command:-codex} not installed)"
    fi
    echo "- codex config"
    if (( ! dry_run )); then
      ai_litellm_render_codex_config || failed=1
    fi
  else
    echo "- codex catalog/config skipped ($codex_wrapper not installed)"
  fi

  if ai_litellm_harness_descriptor claude >/dev/null 2>&1; then
    echo "- claude settings"
    if (( ! dry_run )); then
      ai_litellm_render_claude_settings claude || failed=1
    fi
  fi

  if ai_litellm_harness_descriptor opencode >/dev/null 2>&1; then
    echo "- opencode config"
    if (( ! dry_run )); then
      ai_litellm_render_opencode_config opencode || failed=1
    fi
  fi

  if (( restart )); then
    echo "- proxy restart (reloads model_info + enforcement)"
    ai_litellm_restart || failed=1
  else
    echo "- proxy restart skipped"
  fi

  echo "- claude/goose output limits derive at next launch"
  return $failed
}

ai_litellm_doctor_local_route_uniqueness() {
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
names = Array(config["model_list"]).map { |entry| entry["model_name"] }.compact
local_names = names.select { |name| name.start_with?("local-") }
counts = Hash.new(0)
local_names.each { |name| counts[name] += 1 }
duplicates = counts.select { |_name, count| count > 1 }.keys
if duplicates.any?
  warn "duplicate local model_name entries: #{duplicates.join(", ")}"
  exit 1
end
' "$AI_LITELLM_CONFIG"
}

ai_litellm_doctor_runtimes() {
  local failed=0 rt
  for rt in "${(@f)$(ai_litellm_runtime_names 2>/dev/null)}"; do
    [[ -n "$rt" ]] || continue
    ai_litellm_doctor_check "runtime block valid: $rt" ai_litellm_runtime_validate "$rt" || failed=1
  done
  return $failed
}

ai_litellm_doctor_runtime() {
  local runtime="$1"
  if [[ -z "$runtime" ]]; then
    echo "Usage: ai-litellm doctor --runtime <name>" >&2
    return 1
  fi

  local failed=0
  echo "ai-litellm doctor --runtime $runtime"
  ai_litellm_doctor_check "runtime block valid" ai_litellm_runtime_validate "$runtime" || failed=1
  ai_litellm_doctor_check "runtime configured" ai_litellm_quiet ai_litellm_runtime_field "$runtime" apiBase || failed=1

  local models_dir
  models_dir="$(ai_litellm_runtime_field "$runtime" modelsDir 2>/dev/null || true)"
  if [[ -n "$models_dir" ]]; then
    ai_litellm_doctor_check "model directory exists" test -d "$models_dir" || failed=1
  else
    echo "fail model directory configured"
    failed=1
  fi

  # Generalized binary check: prefer an explicit startCommandBinary, else derive
  # the binary from the first word of startCommand. Works for any runtime, not omlx.
  local start_binary start_cmd
  start_binary="$(ai_litellm_runtime_field "$runtime" startCommandBinary 2>/dev/null || true)"
  if [[ -z "$start_binary" ]]; then
    start_cmd="$(ai_litellm_runtime_field "$runtime" startCommand 2>/dev/null || true)"
    start_binary="${start_cmd%% *}"
  fi
  if [[ -n "$start_binary" ]]; then
    ai_litellm_doctor_check "runtime command available: $start_binary" ai_litellm_quiet command -v "$start_binary" || failed=1
  fi

  if ai_litellm_runtime_reachable "$runtime"; then
    echo "ok   runtime endpoint reachable"
    local model
    local -a expected_models
    expected_models=("${(@f)$(ai_litellm_runtime_expected_models "$runtime" 2>/dev/null)}")
    for model in "${expected_models[@]}"; do
      ai_litellm_doctor_check "runtime model available: $model" ai_litellm_runtime_model_available "$runtime" "$model" || failed=1
    done
  else
    echo "fail runtime endpoint reachable"
    echo "hint start manually: $(ai_litellm_runtime_field "$runtime" startCommand 2>/dev/null || printf 'manual start')"
    failed=1
  fi

  return $failed
}

ai_litellm_capabilities() {
  echo "ai-litellm capabilities"
  echo "Proxy: $(ai_litellm_base_url)"
  if ai_litellm_health; then
    echo "Proxy health: ok"
  else
    echo "Proxy health: not reachable"
  fi
  echo "Runtime policy: manual start/stop, early inactive-runtime errors, no fallback"
  echo "LiteLLM drop_params: $(ai_litellm_litellm_setting drop_params 2>/dev/null || printf 'unset')"
  echo
  ai_litellm_runtime_status
}

ai_litellm_doctor() {
  if [[ "$1" == "--runtime" ]]; then
    shift
    ai_litellm_doctor_runtime "$@"
    return $?
  fi

  local probe_routes=0
  local -a probe_models
  while (( $# > 0 )); do
    case "$1" in
      --probe-routes)
        probe_routes=1
        ;;
      --probe-model)
        shift
        [[ -n "$1" ]] || {
          echo "Missing model after --probe-model" >&2
          return 1
        }
        probe_models+=("$1")
        ;;
      *)
        echo "Unknown doctor option: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local failed=0
  echo "ai-litellm doctor"
  ai_litellm_doctor_warn_env
  ai_litellm_doctor_check "config exists" test -f "$AI_LITELLM_CONFIG" || failed=1
  ai_litellm_doctor_check "settings exists" test -f "$AI_LITELLM_SETTINGS" || failed=1
  ai_litellm_doctor_check "lib syntax" zsh -n "$AI_LITELLM_CONFIG_HOME/ai-litellm/lib.zsh" || failed=1
  ai_litellm_doctor_check "claude helper syntax" zsh -n "$AI_LITELLM_CONFIG_HOME/claude-litellm/shell.zsh" || failed=1
  ai_litellm_doctor_check "codex helper syntax" zsh -n "$AI_LITELLM_CONFIG_HOME/codex-litellm/shell.zsh" || failed=1
  ai_litellm_doctor_check "ai-litellm command syntax" zsh -n "$AI_LITELLM_BIN_DIR/ai-litellm" || failed=1
  ai_litellm_doctor_check "claude-litellm command syntax" zsh -n "$AI_LITELLM_BIN_DIR/claude-litellm" || failed=1
  ai_litellm_doctor_check "codex-litellm command syntax" zsh -n "$AI_LITELLM_BIN_DIR/codex-litellm" || failed=1
  ai_litellm_doctor_check "goose-litellm command syntax" zsh -n "$AI_LITELLM_BIN_DIR/goose-litellm" || failed=1
  ai_litellm_doctor_check "opencode-litellm command syntax" zsh -n "$AI_LITELLM_BIN_DIR/opencode-litellm" || failed=1
  ai_litellm_doctor_check "litellm command available" ai_litellm_quiet command -v litellm || failed=1
  ai_litellm_doctor_check "node command available" ai_litellm_quiet command -v node || failed=1
  ai_litellm_doctor_check "curl command available" ai_litellm_quiet command -v curl || failed=1
  ai_litellm_doctor_check "jq command available" ai_litellm_quiet command -v jq || failed=1
  # Only require the OpenRouter key if the registry actually references it (same
  # gate as ai_litellm_start), so a non-OpenRouter fabric does not false-FAIL.
  if grep -q 'os\.environ/OPENROUTER_API_KEY' "$AI_LITELLM_CONFIG" 2>/dev/null; then
    ai_litellm_doctor_check "OpenRouter key available" ai_litellm_quiet ai_litellm_openrouter_key || failed=1
  fi
  # Every other provider key the registry references must resolve too.
  local _pref
  for _pref in ${(f)"$(ai_litellm_config_env_refs 2>/dev/null)"}; do
    case "$_pref" in
      OPENROUTER_API_KEY|LITELLM_MASTER_KEY) continue ;;
    esac
    ai_litellm_doctor_check "provider key available: $_pref" ai_litellm_quiet ai_litellm_resolve_secret_var "$_pref" || failed=1
  done
  ai_litellm_doctor_check "LiteLLM master key available" ai_litellm_quiet ai_litellm_master_key || failed=1
  ai_litellm_doctor_harnesses || failed=1
  ai_litellm_doctor_check "Codex generated config follows ai-litellm base URL" ai_litellm_doctor_codex_config_base_url || failed=1
  ai_litellm_doctor_check "OpenCode generated config follows ai-litellm base URL" ai_litellm_doctor_opencode_config_base_url || failed=1
  ai_litellm_doctor_check "Codex shortcuts do not shadow subcommands" ai_litellm_doctor_shortcuts || failed=1
  ai_litellm_doctor_check "local model routes are unique" ai_litellm_doctor_local_route_uniqueness || failed=1
  ai_litellm_doctor_check "harness configs match single-source limits" ai_litellm_doctor_limit_sync || failed=1
  ai_litellm_doctor_check "harness output reservations leave input budget" ai_litellm_context_harness_reservations_ok || failed=1
  ai_litellm_doctor_check "harness reasoning configs match descriptors" ai_litellm_doctor_reasoning_sync || failed=1
  ai_litellm_doctor_reasoning_capability_truth
  ai_litellm_doctor_runtimes || failed=1
  ai_litellm_doctor_check "runtime/registry consistency" ai_litellm_runtime_consistency || failed=1
  ai_litellm_doctor_check "runtime endpoints do not collide" ai_litellm_runtime_ports_ok || failed=1
  if ai_litellm_health; then
    echo "ok   proxy health"
    ai_litellm_doctor_check "route metadata reachable" ai_litellm_quiet ai_litellm_route_info || failed=1
    ai_litellm_doctor_check "running proxy loaded current config" ai_litellm_proxy_config_current || failed=1
    ai_litellm_doctor_check "running proxy routes match config" ai_litellm_proxy_registry_matches_file || failed=1
  else
    echo "warn proxy health not reachable"
  fi
  if (( probe_routes )); then
    if (( ${#probe_models[@]} == 0 )); then
      probe_models=("${(@f)$(ai_litellm_model_names)}")
    fi
    ai_litellm_probe_routes "${probe_models[@]}" || failed=1
  elif (( ${#probe_models[@]} > 0 )); then
    ai_litellm_probe_routes "${probe_models[@]}" || failed=1
  fi
  return $failed
}

# Token-limit table from the single source. Powers `ai-litellm model limits`.
ai_litellm_limits_table() {
  local filter="$1"
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
filter = ARGV[1] || ""
printf("%-22s %-12s %-12s\n", "model_name", "context", "output")
Array(config["model_list"]).each do |e|
  name = e["model_name"]
  next if !filter.empty? && name != filter
  mi = e["model_info"] || {}
  printf("%-22s %-12s %-12s\n", name, (mi["max_input_tokens"] || "-").to_s, (mi["max_output_tokens"] || "-").to_s)
end
' "$AI_LITELLM_CONFIG" "$filter"
}

# Provider/backend reasoning capability table from the LiteLLM registry. It
# shows route-level defaults before any harness intent is considered.
ai_litellm_model_reasoning_table() {
  local filter="$1"
  local litellm_python
  litellm_python="$(ai_litellm_litellm_python 2>/dev/null)" || {
    echo "Missing LiteLLM Python runtime; cannot inspect local capability." >&2
    return 1
  }

  "$litellm_python" - "$AI_LITELLM_CONFIG" "$AI_LITELLM_REASONING_OBS_FILE" "$filter" <<'PY'
import json
import sys

import yaml

try:
    import litellm
except Exception as exc:
    print(f"Failed to import litellm: {exc}", file=sys.stderr)
    raise SystemExit(1)

config_path, observations_path, raw_filter = sys.argv[1:4]
model_filter = raw_filter or ""
with open(config_path, "r", encoding="utf-8") as fh:
    config = yaml.safe_load(fh) or {}

try:
    with open(observations_path, "r", encoding="utf-8") as fh:
        observations = json.load(fh)
except Exception:
    observations = {}

drop_params = bool((config.get("litellm_settings") or {}).get("drop_params"))


def provider_for(model):
    return (model or "-").split("/", 1)[0]


def provider_default(entry):
    litellm_params = entry.get("litellm_params") or {}
    reasoning = litellm_params.get("reasoning")
    reasoning_effort = litellm_params.get("reasoning_effort")
    if isinstance(reasoning, dict):
        effort = reasoning.get("effort")
        return f"effort={effort}" if effort else "reasoning"
    if reasoning is not None:
        return str(reasoning)
    if reasoning_effort is not None:
        return f"effort={reasoning_effort}"
    return str((entry.get("model_info") or {}).get("reasoning_default") or "-")


def local_capability(backend):
    params = []
    supports = False
    err = None
    try:
        supports = bool(litellm.supports_reasoning(model=backend))
    except Exception as exc:
        err = f"{type(exc).__name__}"
    try:
        params = litellm.get_supported_openai_params(model=backend) or []
    except Exception as exc:
        err = err or f"{type(exc).__name__}"
    param_support = any(p in params for p in ("reasoning_effort", "reasoning", "thinking"))
    return supports or param_support, params, err


def local_wire(declared, params):
    if not declared:
        return "-"
    if "reasoning_effort" in params:
        return "reasoning_effort"
    if "reasoning" in params:
        return "reasoning"
    if "thinking" in params:
        return "thinking"
    return "-"


def drop_risk(declared, local_supported, observed):
    if not declared:
        return "-"
    if observed and observed.get("status") == "observed":
        return "low(obs)"
    if local_supported:
        return "low"
    return "high(drop)" if drop_params else "high(error)"


def raw_observed_for(name, backend):
    models = observations.get("models") or {}
    obs = models.get(name)
    if obs:
        observed_backend = obs.get("provider_model")
        if not observed_backend or observed_backend == backend:
            return obs
    for candidate in models.values():
        if candidate.get("provider_model") == backend and candidate.get("status") == "observed":
            return candidate
    return None


def observed_for(name, backend):
    obs = raw_observed_for(name, backend)
    if not obs:
        return "-"
    status = obs.get("status") or "unknown"
    tokens = obs.get("reasoning_tokens")
    if status == "observed":
        return f"yes({tokens or 0})"
    if status == "not_observed":
        return f"no({tokens or 0})"
    if status == "error":
        return "error"
    return status


print(
    "%-22s %-42s %-9s %-12s %-14s %-22s %-12s %-12s"
    % (
        "model_name",
        "provider_model",
        "declared",
        "litellm_cap",
        "default",
        "local_wire",
        "drop_risk",
        "observed",
    )
)
for entry in config.get("model_list") or []:
    name = entry.get("model_name") or ""
    backend = (entry.get("litellm_params") or {}).get("model") or "-"
    if model_filter and model_filter not in (name, backend):
        continue
    mi = entry.get("model_info") or {}
    declared = mi.get("supports_reasoning") is True
    local_supported, params, err = local_capability(backend)
    local_label = "yes" if local_supported else "no"
    if err and not local_supported:
        local_label = f"no({err})"
    print(
        "%-22s %-42s %-9s %-12s %-14s %-22s %-12s %-12s"
        % (
            name,
            backend,
            "yes" if declared else "no",
            local_label,
            provider_default(entry),
            local_wire(declared, params),
            drop_risk(declared, local_supported, raw_observed_for(name, backend)),
            observed_for(name, backend),
        )
    )
PY
}

ai_litellm_model_reasoning_allowed_efforts() {
  local model="$1"
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
target = ARGV[1]
entry = Array(config["model_list"]).find { |item| item["model_name"] == target }
abort("Unknown LiteLLM model_name: #{target}") unless entry
supports = entry.dig("model_info", "supports_reasoning") == true
abort("Model does not declare supports_reasoning: true: #{target}") unless supports
backend = entry.dig("litellm_params", "model").to_s
provider = backend.split("/", 2).first
allowed =
  case provider
  when "openrouter"
    %w[none minimal low medium high xhigh]
  when "openai"
    %w[minimal low medium high]
  else
    %w[none minimal low medium high xhigh max]
  end
puts allowed.join(" ")
' "$AI_LITELLM_CONFIG" "$model"
}

ai_litellm_model_reasoning_update() {
  local mode="$1"
  local model="$2"
  local effort="${3:-}"
  if [[ -z "$mode" || -z "$model" ]]; then
    echo "Usage: ai-litellm model reasoning set <model> <effort>" >&2
    echo "       ai-litellm model reasoning unset <model>" >&2
    return 1
  fi
  if [[ "$mode" == "set" && -z "$effort" ]]; then
    echo "Usage: ai-litellm model reasoning set <model> <effort>" >&2
    return 1
  fi

  if [[ "$mode" == "set" ]]; then
    local allowed
    allowed="$(ai_litellm_model_reasoning_allowed_efforts "$model")" || return $?
    case " $allowed " in
      *" $effort "*) ;;
      *)
        echo "Unsupported provider reasoning effort for $model: $effort (allowed: ${allowed// /, })" >&2
        return 1
        ;;
    esac
  fi

  ruby -ryaml -e '
path, mode, target, effort = ARGV
config = (YAML.load_file(path, aliases: true) rescue YAML.load_file(path))
entry = Array(config["model_list"]).find { |item| item["model_name"] == target }
abort("Unknown LiteLLM model_name: #{target}") unless entry
if mode == "set" && entry.dig("model_info", "supports_reasoning") != true
  abort("Model does not declare supports_reasoning: true: #{target}")
end

backend = entry.dig("litellm_params", "model").to_s
# Reasoning is a property of the UNDERLYING model, like the token-limit anchors.
# Apply mutations to every surface model_name that routes to the same backend.
targets = Array(config["model_list"])
  .select { |item| item.dig("litellm_params", "model").to_s == backend }
  .map { |item| item["model_name"] }.compact

def atomic_write(path, content)
  stat = File.stat(path)
  tmp = "#{path}.tmp.#{$$}"
  File.write(tmp, content)
  File.chmod(stat.mode & 0777, tmp)
  File.rename(tmp, path)
ensure
  File.delete(tmp) if tmp && File.exist?(tmp)
end

def entry_range(lines, name)
  start = lines.index { |line| line.match?(/^  - model_name:\s*#{Regexp.escape(name)}\s*$/) }
  return nil unless start
  finish = ((start + 1)...lines.length).find { |idx| lines[idx].match?(/^  - model_name:\s*/) } || lines.length
  [start, finish]
end

def strip_reasoning_defaults!(lines, start, finish)
  idx = start + 1
  while idx < finish
    if lines[idx].match?(/^      reasoning:\s*/) || lines[idx].match?(/^      reasoning_effort:\s*/)
      lines.delete_at(idx)
      finish -= 1
      while idx < finish && lines[idx].match?(/^        /)
        lines.delete_at(idx)
        finish -= 1
      end
      next
    end
    idx += 1
  end
  finish
end

lines = File.read(path).lines
targets.each do |name|
  range = entry_range(lines, name)
  next unless range
  start, finish = range
  litellm_params = (start...finish).find { |idx| lines[idx].match?(/^    litellm_params:\s*$/) }
  finish = strip_reasoning_defaults!(lines, start, finish)
  next unless mode == "set"
  next unless litellm_params
  # reasoning_effort is the contracted LiteLLM key (mapped to OpenRouter
  # reasoning:{effort} and to OpenAI reasoning_effort). Never hand-write a raw
  # top-level reasoning: key.
  insert = ((litellm_params + 1)...finish).find { |line_idx| lines[line_idx].match?(/^    model_info:/) } || finish
  lines.insert(insert, %(      reasoning_effort: "#{effort}"\n))
end

atomic_write(path, lines.join)
STDOUT.puts(mode == "set" ? "Applied to: #{targets.join(", ")}" : "Cleared: #{targets.join(", ")}")
' "$AI_LITELLM_CONFIG" "$mode" "$model" "$effort" || return $?

  if [[ "$mode" == "set" ]]; then
    echo "Updated provider reasoning default for $model's backend -> effort=$effort"
  else
    echo "Cleared provider reasoning default for $model's backend"
  fi
  echo "Run 'ai-litellm sync' to apply it to the running proxy."
}

ai_litellm_model_reasoning_set() {
  ai_litellm_model_reasoning_update set "$@"
}

ai_litellm_model_reasoning_unset() {
  ai_litellm_model_reasoning_update unset "$@"
}

ai_litellm_reasoning_observation_record() {
  local observation_json="$1"
  mkdir -p "$AI_LITELLM_HOME"
  node -e '
const fs = require("fs");
const [file, raw] = process.argv.slice(1);
const observation = JSON.parse(raw);
let state = {models: {}};
try {
  state = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (_) {}
if (!state || typeof state !== "object" || Array.isArray(state)) state = {models: {}};
if (!state.models || typeof state.models !== "object" || Array.isArray(state.models)) state.models = {};
state.models[observation.model_name] = observation;
const tmp = `${file}.tmp.${process.pid}`;
try {
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n", {mode: 0o600});
  fs.renameSync(tmp, file);
} catch (error) {
  try { fs.unlinkSync(tmp); } catch (_) {}
  throw error;
}
' "$AI_LITELLM_REASONING_OBS_FILE" "$observation_json"
}

ai_litellm_model_reasoning_probe() {
  local model="$1"
  local effort="${2:-xhigh}"
  if [[ -z "$model" ]]; then
    echo "Usage: ai-litellm model reasoning probe <model> [effort]" >&2
    return 1
  fi

  ai_litellm_model_exists "$model" || {
    echo "Unknown LiteLLM model_name: $model" >&2
    return 1
  }
  local allowed
  allowed="$(ai_litellm_model_reasoning_allowed_efforts "$model")" || return $?
  case " $allowed " in
    *" $effort "*) ;;
    *)
      echo "Unsupported reasoning effort for probe: $effort (allowed: ${allowed// /, })" >&2
      return 1
      ;;
  esac
  if ! ai_litellm_health; then
    echo "LiteLLM proxy is not reachable at $(ai_litellm_base_url); reasoning probe will not auto-start it." >&2
    return 1
  fi

  local master_key backend payload tmp http_code observation_json
  master_key="$(ai_litellm_master_key 2>/dev/null)" || {
    echo "Missing LiteLLM master key." >&2
    return 1
  }
  backend="$(ai_litellm_model_backend "$model" 2>/dev/null || printf '-')"
  payload="$(jq -nc --arg model "$model" --arg effort "$effort" '{
    model: $model,
    messages: [{role: "user", content: "Reply with exactly OK."}],
    max_tokens: 64,
    temperature: 0,
    reasoning_effort: $effort
  }')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/ai-litellm-reasoning-probe.XXXXXX")" || return 1

  http_code="$(
    ai_litellm_curl_auth "$master_key" --max-time 90 -sS -o "$tmp" -w "%{http_code}" \
      -H "Content-Type: application/json" \
      "$(ai_litellm_api_base_url)/chat/completions" \
      -d "$payload"
  )"

  observation_json="$(jq -nc \
    --arg model "$model" \
    --arg backend "$backend" \
    --arg effort "$effort" \
    --arg path "proxy:chat.completions:reasoning_effort" \
    --arg http_code "$http_code" \
    --slurpfile response "$tmp" '
      def message:
        ($response[0].choices[0].message // {});
      def reasoning_tokens:
        ($response[0].usage.completion_tokens_details.reasoning_tokens // 0);
      def has_reasoning:
        ((message.reasoning? // null) != null) or
        ((message.reasoning_content? // null) != null) or
        ((message.reasoning_details? // null) != null);
      def ok: ($http_code | test("^2"));
      {
        timestamp: (now | todateiso8601),
        model_name: $model,
        provider_model: $backend,
        effort: $effort,
        path: $path,
        http_code: $http_code
      }
      + if ok then
          {
            status: (if (reasoning_tokens > 0 or has_reasoning) then "observed" else "not_observed" end),
            reasoning_tokens: reasoning_tokens,
            has_reasoning: has_reasoning,
            response_id: ($response[0].id // null)
          }
        else
          {
            status: "error",
            reasoning_tokens: 0,
            has_reasoning: false,
            error: ($response[0].error.message // $response[0].message // ($response[0] | tostring))
          }
        end
    ')" || {
    rm -f "$tmp"
    echo "Failed to parse reasoning probe response." >&2
    return 1
  }
  rm -f "$tmp"

  ai_litellm_reasoning_observation_record "$observation_json" || return $?
  print -r -- "$observation_json" | jq '{model_name, provider_model, effort, path, status, reasoning_tokens, has_reasoning, http_code, error}'

  local probe_status
  probe_status="$(print -r -- "$observation_json" | jq -r '.status')"
  [[ "$probe_status" != "error" ]]
}

# Harness reasoning resolver preview. Each adapter translates its local model
# selection and effort semantics into a common shape.
ai_litellm_harness_reasoning_table() {
  local filter="$1"
  ruby -rjson -ryaml -e '
require "set"

config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
harness_dir = ARGV[1]
filter = ARGV[2] || ""

registry = {}
Array(config["model_list"]).each do |entry|
  registry[entry["model_name"]] = entry if entry["model_name"]
end

def read_json(path)
  return {} unless path && File.file?(path)
  JSON.parse(File.read(path))
rescue
  {}
end

def provider_model(registry, model)
  registry.dig(model, "litellm_params", "model") || "-"
end

def supports_reasoning(registry, model)
  registry.dig(model, "model_info", "supports_reasoning") == true
end

def provider_default(registry, model)
  entry = registry[model]
  return "-" unless entry
  reasoning = entry.dig("litellm_params", "reasoning")
  reasoning_effort = entry.dig("litellm_params", "reasoning_effort")
  if reasoning.is_a?(Hash)
    effort = reasoning["effort"]
    return "effort=#{effort}" if effort
    return "reasoning"
  elsif !reasoning.nil?
    return reasoning.to_s
  elsif !reasoning_effort.nil?
    return "effort=#{reasoning_effort}"
  end
  entry.dig("model_info", "reasoning_default") || "-"
end

def adapter_default_control(adapter)
  case adapter
  when "claude-code", "codex-cli"
    "intent"
  else
    "none"
  end
end

def adapter_default_effort(adapter, descriptor)
  case adapter
  when "codex-cli"
    descriptor.dig("adapterConfig", "modelReasoningEffort") || "auto"
  when "claude-code"
    "auto"
  else
    "-"
  end
end

def effective(control, provider_support, effort)
  if control == "none"
    provider_support ? "provider-default" : "no-reasoning"
  elsif effort.to_s == "auto"
    provider_support ? "harness-auto" : "no-reasoning"
  elsif provider_support
    "harness-intent"
  else
    "intent-unsupported"
  end
end

def add_row(rows, harness, selection, resolved, descriptor, registry)
  adapter = descriptor["adapter"]
  reasoning = descriptor.dig("adapterConfig", "reasoning") || {}
  control = reasoning["control"] || adapter_default_control(adapter)
  effort = reasoning["effort"] || adapter_default_effort(adapter, descriptor)
  if adapter == "codex-cli"
    effort = descriptor.dig("adapterConfig", "modelReasoningEffort") || effort
  elsif adapter == "claude-code"
    settings_arg = read_json(descriptor.dig("paths", "settingsArg"))
    effort = settings_arg["effortLevel"] || effort
  end
  provider_support = supports_reasoning(registry, resolved)
  rows << {
    harness: harness,
    adapter: adapter,
    selection: selection,
    resolved: resolved || "-",
    provider_model: provider_model(registry, resolved),
    provider_reasoning: provider_support ? "yes" : "no",
    provider_default: provider_default(registry, resolved),
    control: control,
    effort: effort,
    source: reasoning["source"] || "-",
    effective: effective(control, provider_support, effort),
    confidence: reasoning["confidence"] || "inferred"
  }
end

def descriptor_paths(harness_dir)
  Dir[File.join(harness_dir, "*.json")].reject { |p| File.basename(p) == "schema.json" }.sort
end

rows = []
descriptor_paths(harness_dir).each do |path|
  descriptor = read_json(path)
  harness = descriptor["name"] || File.basename(path, ".json")
  next if !filter.empty? && harness != filter
  adapter = descriptor["adapter"]

  case adapter
  when "claude-code"
    settings = read_json(descriptor.dig("paths", "settings"))
    tiers = Array(descriptor.dig("models", "tiers"))
    aliases = settings["aliases"] || {}
    default = settings["default"] || "sonnet"
    default_resolved = tiers.include?(default) ? aliases[default] : default
    add_row(rows, harness, "default(#{default})", default_resolved, descriptor, registry)
    tiers.each do |tier|
      add_row(rows, harness, tier, aliases[tier], descriptor, registry)
    end
  when "codex-cli"
    selections = []
    default = descriptor.dig("models", "default")
    selections << ["default(#{default})", default] if default
    settings = read_json(descriptor.dig("paths", "settings"))
    Array((settings["aliases"] || {}).values).uniq.each { |model| selections << [model, model] }
    Array(descriptor.dig("models", "localCatalogEntries")).each do |entry|
      selections << [entry["slug"], entry["slug"]] if entry["slug"]
    end
    registry.keys.grep(/^codex-/).each { |model| selections << [model, model] }
    seen = Set.new
    selections.each do |selection, model|
      next unless model && registry.key?(model)
      key = [selection, model]
      next if seen.include?(key)
      seen.add(key)
      add_row(rows, harness, selection, model, descriptor, registry)
    end
  when "env-injector", "opencode-cli"
    default = descriptor.dig("models", "default")
    add_row(rows, harness, "default(#{default})", default, descriptor, registry) if default
    small = descriptor.dig("models", "small")
    add_row(rows, harness, "small(#{small})", small, descriptor, registry) if small
  else
    default = descriptor.dig("models", "default")
    add_row(rows, harness, "default(#{default})", default, descriptor, registry) if default
  end
end

printf("%-9s %-13s %-22s %-22s %-42s %-10s %-9s %-8s %-28s %-18s %-10s\n",
  "harness", "adapter", "selection", "resolved_model", "provider_model",
  "prov_reas", "control", "effort", "source", "effective", "confidence")
rows.each do |row|
  printf("%-9s %-13s %-22s %-22s %-42s %-10s %-9s %-8s %-28s %-18s %-10s\n",
    row[:harness], row[:adapter], row[:selection], row[:resolved],
    row[:provider_model], row[:provider_reasoning], row[:control],
    row[:effort].to_s, row[:source], row[:effective], row[:confidence])
end
' "$AI_LITELLM_CONFIG" "$AI_LITELLM_HARNESSES_DIR" "$filter"
}

ai_litellm_harness_reasoning_update() {
  local mode="$1"
  local harness="$2"
  local effort="${3:-}"
  if [[ -z "$mode" || -z "$harness" ]]; then
    echo "Usage: ai-litellm harness reasoning set <name> <effort>" >&2
    echo "       ai-litellm harness reasoning unset <name>" >&2
    return 1
  fi
  if [[ "$mode" == "set" && -z "$effort" ]]; then
    echo "Usage: ai-litellm harness reasoning set <name> <effort>" >&2
    return 1
  fi

  local descriptor
  descriptor="$(ai_litellm_harness_descriptor "$harness")" || {
    echo "Unknown harness: $harness" >&2
    return 1
  }

  node -e '
const fs = require("fs");
const [file, mode, rawEffort = ""] = process.argv.slice(1);
const descriptor = JSON.parse(fs.readFileSync(file, "utf8"));
const adapter = descriptor.adapter;
const adapterConfig = descriptor.adapterConfig ||= {};
const effort = String(rawEffort).toLowerCase();

const fail = (message) => {
  console.error(message);
  process.exit(1);
};
const assertAllowed = (allowed) => {
  if (!allowed.includes(effort)) {
    fail(`Unsupported reasoning effort for ${adapter}: ${effort} (allowed: ${allowed.join(", ")})`);
  }
};
const setReasoning = (value) => {
  adapterConfig.reasoning = value;
};

const noHarnessControl = (notes) => ({
  control: "none",
  source: "none",
  wire: "provider-default",
  confidence: "unknown",
  ...(notes ? {notes} : {})
});
const adapterReasoning = {
  "claude-code": {
    allowed: ["auto", "low", "medium", "high", "xhigh", "max"],
    unsetEffort: "auto",
    build(value) {
      if (value === "auto") {
        return {
          control: "intent",
          source: "claude-code-effort",
          effort: "auto",
          wire: "tier/model+optional-cli-flag:--effort",
          confidence: "inferred",
          notes: "Claude Code tier selection can affect effort defaults; explicit efforts are passed with --effort."
        };
      }
      return {
        control: "intent",
        source: "claude-code-effort",
        effort: value,
        wire: "cli-flag:--effort",
        flag: "--effort",
        confidence: "configured",
        notes: "User-provided --effort at launch overrides this descriptor default."
      };
    }
  },
  "codex-cli": {
    allowed: ["low", "medium", "high", "xhigh"],
    unsetEffort: "xhigh",
    build(value) {
      adapterConfig.modelReasoningEffort = value;
      return {
        control: "intent",
        source: "codex-model_reasoning_effort",
        effort: value,
        wire: "config:model_reasoning_effort",
        confidence: "configured"
      };
    }
  },
  "opencode-cli": {
    allowed: ["auto", "none", "minimal", "low", "medium", "high", "max"],
    unsetEffort: "none",
    build(value) {
      if (value === "auto" || value === "none") return noHarnessControl();
      return {
        control: "intent",
        source: "opencode-variant",
        effort: value,
        wire: "run-cli-flag:--variant",
        flag: "--variant",
        scope: "run",
        confidence: "configured",
        notes: "Applied to opencode run; user-provided --variant overrides this descriptor default."
      };
    }
  },
  "env-injector": {
    allowed: ["auto", "none"],
    unsetEffort: "none",
    build() {
      return noHarnessControl("This harness exposes no native reasoning-effort control.");
    }
  }
};

if (!adapterReasoning[adapter]) fail(`Unsupported harness adapter for reasoning mutation: ${adapter}`);
if (mode === "set") {
  assertAllowed(adapterReasoning[adapter].allowed);
  setReasoning(adapterReasoning[adapter].build(effort));
} else if (mode === "unset") {
  setReasoning(adapterReasoning[adapter].build(adapterReasoning[adapter].unsetEffort));
} else {
  fail(`Unsupported reasoning update mode: ${mode}`);
}

const tmp = `${file}.tmp.${process.pid}`;
const modeBits = fs.statSync(file).mode & 0o777;
try {
  fs.writeFileSync(tmp, JSON.stringify(descriptor, null, 2) + "\n", {mode: modeBits});
  fs.renameSync(tmp, file);
} catch (error) {
  try { fs.unlinkSync(tmp); } catch (_) {}
  throw error;
}
' "$descriptor" "$mode" "$effort" || return $?

  if [[ "$mode" == "set" ]]; then
    echo "Updated harness reasoning default: $harness -> $effort"
  else
    echo "Reset harness reasoning default: $harness"
  fi
  echo "Run 'ai-litellm sync' to regenerate derived configs where needed."
}

ai_litellm_harness_reasoning_set() {
  ai_litellm_harness_reasoning_update set "$@"
}

ai_litellm_harness_reasoning_unset() {
  ai_litellm_harness_reasoning_update unset "$@"
}

ai_litellm_context_matrix() {
  local filter="$1"
  ruby -rjson -ryaml -ropen3 -e '
config_path, settings_path, harness_dir, home, base_url, api_base_url, filter = ARGV
filter ||= ""

NATIVE_CODEX_MODEL = "gpt-5.5"
NATIVE_CODEX_PROVIDER_MODEL = "openai/gpt-5.5"
NATIVE_CODEX_PRODUCT_CONTEXT = 400000
NATIVE_CODEX_OUTPUT_TOKENS = 128000
OPENAI_API_GPT55_CONTEXT = 1050000
OPENAI_API_GPT55_OUTPUT_TOKENS = 128000

def read_json(path)
  return nil unless path && File.file?(path)
  JSON.parse(File.read(path))
rescue
  nil
end

def toml_value(path, key)
  return nil unless path && File.file?(path)
  File.read(path)[/^\s*#{Regexp.escape(key)}\s*=\s*"([^"]+)"/, 1]
rescue
  nil
end

def run_json(*cmd)
  out, status = Open3.capture2e(*cmd)
  return nil unless status.success?
  JSON.parse(out)
rescue
  nil
end

def codex_model(cmd)
  payload = run_json(*cmd)
  Array(payload && payload["models"]).find { |m| m["slug"] == NATIVE_CODEX_MODEL }
end

def model_config_context(models_dir, model)
  path = File.join(models_dir.to_s, model.to_s, "config.json")
  payload = read_json(path)
  return nil unless payload
  payload.dig("text_config", "max_position_embeddings") ||
    payload["max_position_embeddings"] ||
    payload["max_sequence_length"] ||
    payload["max_model_len"]
end

def fmt(value)
  value.nil? || value.to_s.empty? ? "-" : value.to_s
end

def fmt_pair(ctx, out)
  return "-" if ctx.nil? && out.nil?
  "#{fmt(ctx)}/#{fmt(out)}"
end

def provider_model(entry)
  entry&.dig("litellm_params", "model") || "-"
end

def add_row(rows, attrs)
  rows << {
    surface: attrs[:surface],
    selection: attrs[:selection] || "-",
    auth_lane: attrs[:auth_lane] || "-",
    provider_model: attrs[:provider_model] || "-",
    budget_kind: attrs[:budget_kind] || "-",
    declared: fmt_pair(attrs[:declared_context], attrs[:declared_output]),
    configured: fmt_pair(attrs[:configured_context], attrs[:configured_output]),
    observed: fmt(attrs[:observed_context]),
    effective_input: fmt(attrs[:effective_input_budget]),
    enforcement: attrs[:enforcement_layer] || "-",
    confidence: attrs[:source_confidence] || "unknown"
  }
end

def include_row?(row, filter)
  return true if filter.nil? || filter.empty?
  [row[:surface], row[:selection], row[:provider_model], row[:budget_kind], row[:confidence]].any? do |value|
    value.to_s.include?(filter)
  end
end

config = (YAML.load_file(config_path, aliases: true) rescue YAML.load_file(config_path))
settings = read_json(settings_path) || {}
registry = {}
Array(config["model_list"]).each do |entry|
  registry[entry["model_name"]] = entry if entry["model_name"]
end
pre_call = config.dig("router_settings", "enable_pre_call_checks") == true
router_enforcement = pre_call ? "LiteLLM pre-call" : "provider-only"

rows = []

native_auth = read_json(File.join(home, ".codex", "auth.json")) || {}
auth_lane =
  if native_auth["auth_mode"]
    native_auth["auth_mode"].to_s
  elsif native_auth["tokens"]
    "chatgpt"
  elsif native_auth["OPENAI_API_KEY"]
    "api-key"
  else
    "unknown"
  end

active_codex = codex_model(["codex", "debug", "models"])
bundled_codex = codex_model(["codex", "debug", "models", "--bundled"])
active_ctx = active_codex && active_codex["context_window"]
active_pct = active_codex && active_codex["effective_context_window_percent"]
active_effective = active_ctx && active_pct ? (active_ctx.to_f * active_pct.to_f / 100.0).floor : nil
bundled_ctx = bundled_codex && bundled_codex["context_window"]
native_config = File.join(home, ".codex", "config.toml")
native_override = toml_value(native_config, "model_catalog_json") || toml_value(native_config, "model_context_window")
native_confidence = native_override ? "local-override" : "official+bundled"

add_row(rows,
  surface: "codex-app-oauth",
  selection: "default(#{NATIVE_CODEX_MODEL})",
  auth_lane: auth_lane,
  provider_model: NATIVE_CODEX_PROVIDER_MODEL,
  budget_kind: "harness-session",
  declared_context: NATIVE_CODEX_PRODUCT_CONTEXT,
  declared_output: NATIVE_CODEX_OUTPUT_TOKENS,
  configured_context: active_ctx || bundled_ctx,
  observed_context: nil,
  effective_input_budget: active_effective,
  enforcement_layer: "Codex product",
  source_confidence: "#{native_confidence}; app-unprobed")

add_row(rows,
  surface: "codex-cli-oauth",
  selection: "default(#{NATIVE_CODEX_MODEL})",
  auth_lane: auth_lane,
  provider_model: NATIVE_CODEX_PROVIDER_MODEL,
  budget_kind: "harness-session",
  declared_context: NATIVE_CODEX_PRODUCT_CONTEXT,
  declared_output: NATIVE_CODEX_OUTPUT_TOKENS,
  configured_context: active_ctx || bundled_ctx,
  observed_context: active_effective,
  effective_input_budget: active_effective,
  enforcement_layer: "Codex catalog",
  source_confidence: native_confidence)

add_row(rows,
  surface: "codex-cli-api",
  selection: NATIVE_CODEX_MODEL,
  auth_lane: "api-key",
  provider_model: NATIVE_CODEX_PROVIDER_MODEL,
  budget_kind: "provider-declared",
  declared_context: OPENAI_API_GPT55_CONTEXT,
  declared_output: OPENAI_API_GPT55_OUTPUT_TOKENS,
  configured_context: nil,
  observed_context: nil,
  effective_input_budget: nil,
  enforcement_layer: "OpenAI API",
  source_confidence: "official-api; inactive")

def positive_int(value)
  n = Integer(value)
  n.positive? ? n : nil
rescue
  nil
end

def output_budget(descriptor, selection, model, ctx, out)
  policy = descriptor&.dig("adapterConfig", "outputReservation") || {}
  return nil if policy.empty?

  pick = nil
  [
    ["adapterConfig.outputReservation.perSelection.#{selection}", policy.dig("perSelection", selection)],
    ["adapterConfig.outputReservation.perTier.#{selection}", policy.dig("perTier", selection)],
    ["adapterConfig.outputReservation.perModel.#{model}", policy.dig("perModel", model)],
    ["adapterConfig.outputReservation.default", policy["default"]]
  ].each do |source, value|
    n = positive_int(value)
    if n
      pick = [source, n]
      break
    end
  end

  capability = positive_int(out)
  return nil unless pick || capability

  source, reservation = pick || ["capability-clamped-default", [capability, 32000].compact.min]
  configured_headroom = positive_int(policy["tokenizerHeadroom"]) || 0
  configured_minimum_input = positive_int(policy["minimumInput"]) || 32768
  context = positive_int(ctx)
  headroom = configured_headroom
  minimum_input = configured_minimum_input

  if capability && reservation > capability
    reservation = capability
    source += "+capabilityClamp"
  end
  if context
    headroom = [headroom, (context * 0.1).floor].min
    minimum_input = [minimum_input, [1, (context * 0.5).floor].max].min
    max_reservation_for_minimum_input = context - headroom - minimum_input
    if max_reservation_for_minimum_input < 1
      reservation = 1
      headroom = [0, context - minimum_input - reservation].max
      source += "+tinyWindowClamp"
    elsif reservation > max_reservation_for_minimum_input
      reservation = max_reservation_for_minimum_input
      source += "+minimumInputClamp"
    end
  end

  effective_input = context ? [0, context - reservation - headroom].max : nil
  {
    reservation: reservation,
    tokenizer_headroom: headroom,
    minimum_input: minimum_input,
    effective_input: effective_input,
    source: source
  }
end

def add_litellm_row(rows, registry, model, surface, selection, budget_kind, auth_lane, enforcement, confidence, descriptor = nil)
  entry = registry[model]
  mi = entry && entry["model_info"] || {}
  ctx = mi["max_input_tokens"]
  out = mi["max_output_tokens"]
  budget = output_budget(descriptor, selection, model, ctx, out)
  add_row(rows,
    surface: surface,
    selection: selection,
    auth_lane: auth_lane,
    provider_model: provider_model(entry),
    budget_kind: budget_kind,
    declared_context: ctx,
    declared_output: out,
    configured_context: ctx,
    configured_output: budget ? budget[:reservation] : out,
    observed_context: nil,
    effective_input_budget: budget ? budget[:effective_input] : ctx,
    enforcement_layer: enforcement,
    source_confidence: budget ? "#{confidence}+reservation" : confidence)
end

def descriptor_context(descriptor, harness, router_enforcement)
  context = descriptor.dig("adapterConfig", "context") || {}
  return nil if context["enabled"] == false
  {
    surface: context["surface"] || "#{harness}-litellm",
    budget_kind: context["budgetKind"] || "harness+router",
    auth_lane: context["authLane"] || "litellm-master-key",
    enforcement: context["enforcement"] || router_enforcement,
    confidence: context["confidence"] || "local-config"
  }
end

def descriptor_selections(descriptor, registry)
  models = descriptor["models"] || {}
  settings = read_json(descriptor.dig("paths", "settings")) || {}
  aliases = settings["aliases"] || {}
  rows = []

  if models["mode"] == "tier-aliases"
    tiers = Array(models["tiers"])
    default = settings["default"] || tiers.first
    rows << ["default(#{default})", aliases[default] || default] if default
    tiers.each do |tier|
      rows << [tier, aliases[tier]] if aliases[tier]
    end
  else
    default = models["default"]
    rows << ["default(#{default})", default] if default
    small = models["small"]
    rows << ["small(#{small})", small] if small
    Array(aliases.values).uniq.each do |model|
      rows << [model, model] if model
    end
    Array(models["localCatalogEntries"]).each do |entry|
      model = entry["slug"]
      rows << [model, model] if model
    end
  end

  Array(descriptor.dig("adapterConfig", "context", "selections")).each do |item|
    if item.is_a?(Hash)
      model = item["model"] || item["resolvedModel"] || item["slug"]
      selection = item["selection"] || model
      rows << [selection, model] if model
    elsif item.is_a?(String)
      rows << [item, item]
    end
  end

  seen = {}
  rows.each_with_object([]) do |(selection, model), acc|
    next unless model && registry.key?(model)
    key = [selection, model]
    next if seen[key]
    seen[key] = true
    acc << [selection, model]
  end
end

Dir[File.join(harness_dir, "*.json")].sort.each do |path|
  next if File.basename(path) == "schema.json"
  descriptor = read_json(path) || {}
  harness = descriptor["name"] || File.basename(path, ".json")
  context = descriptor_context(descriptor, harness, router_enforcement)
  next unless context
  descriptor_selections(descriptor, registry).each do |selection, model|
    add_litellm_row(rows, registry, model, context[:surface], selection,
      context[:budget_kind], context[:auth_lane], context[:enforcement], context[:confidence], descriptor)
  end
end

native_claude = read_json(File.join(home, ".claude", "settings.json")) || {}
native_model = native_claude["model"] || "unknown"
add_row(rows,
  surface: "claude-code-native",
  selection: "default(#{native_model})",
  auth_lane: "claude.ai",
  provider_model: native_model,
  budget_kind: "harness-session",
  declared_context: nil,
  declared_output: nil,
  configured_context: nil,
  observed_context: nil,
  effective_input_budget: nil,
  enforcement_layer: "Claude Code",
  source_confidence: "native-unprobed")

Array(settings["runtimes"] || {}).each do |name, rt|
  Array(rt["expectedModels"]).each do |model|
    entry = registry[model]
    mi = entry && entry["model_info"] || {}
    runtime_ctx = model_config_context(rt["modelsDir"], model)
    add_row(rows,
      surface: "#{name}-runtime",
      selection: model,
      auth_lane: "local",
      provider_model: provider_model(entry),
      budget_kind: "runtime-capability",
      declared_context: runtime_ctx,
      declared_output: nil,
      configured_context: mi["max_input_tokens"],
      configured_output: mi["max_output_tokens"],
      observed_context: nil,
      # Effective input is the FLOOR across every layer: a runtime that physically
      # caps below the LiteLLM policy is the real ceiling, not the policy number.
      effective_input_budget: [runtime_ctx, mi["max_input_tokens"]].compact.map(&:to_i).min,
      enforcement_layer: "runtime+LiteLLM",
      source_confidence: runtime_ctx ? "model-file+local-config" : "local-config")
  end
end

rows = rows.select { |row| include_row?(row, filter) }
printf("%-20s %-22s %-18s %-42s %-24s %-17s %-17s %-12s %-15s %-20s %-18s\n",
  "surface", "selection", "auth", "provider_model", "budget_kind",
  "declared(ctx/out)", "configured(ctx/out)", "observed", "effective_input",
  "enforcement", "confidence")
rows.each do |row|
  printf("%-20s %-22s %-18s %-42s %-24s %-17s %-17s %-12s %-15s %-20s %-18s\n",
    row[:surface], row[:selection], row[:auth_lane], row[:provider_model],
    row[:budget_kind], row[:declared], row[:configured], row[:observed],
    row[:effective_input], row[:enforcement], row[:confidence])
end
' "$AI_LITELLM_CONFIG" "$AI_LITELLM_SETTINGS" "$AI_LITELLM_HARNESSES_DIR" "$HOME" "$(ai_litellm_base_url)" "$(ai_litellm_api_base_url)" "$filter"
}

ai_litellm_context_probe_latest_codex_session() {
  ruby -rjson -e '
home = ARGV[0]
files = Dir[File.join(home, ".codex", "sessions", "**", "*.jsonl")].sort_by { |p| File.mtime(p) }.reverse
files.each do |path|
  File.foreach(path) do |line|
    begin
      item = JSON.parse(line)
      payload = item["payload"] || {}
      next unless payload["type"] == "task_started" && payload.key?("model_context_window")
      puts "#{path}: model_context_window=#{payload["model_context_window"]}"
      exit 0
    rescue JSON::ParserError
    end
  end
end
exit 1
' "$HOME"
}

ai_litellm_context_probe_codex_native() {
  local codex_command
  codex_command="$(ai_litellm_harness_json codex command 2>/dev/null || printf 'codex')"
  echo "Surface: $1"
  echo "Auth:"
  if [[ -f "$HOME/.codex/auth.json" ]]; then
    jq '{auth_mode, has_api_key:(.OPENAI_API_KEY!=null and .OPENAI_API_KEY!=""), has_tokens:(.tokens!=null)}' "$HOME/.codex/auth.json"
  else
    echo "  missing $HOME/.codex/auth.json"
  fi
  echo
  echo "Active Codex gpt-5.5 metadata:"
  if command -v "$codex_command" >/dev/null 2>&1; then
    "$codex_command" debug models | jq '.models[] | select(.slug=="gpt-5.5") | {slug,context_window,max_context_window,effective_context_window_percent}'
  else
    echo "  skipped: $codex_command not installed"
  fi
  echo
  echo "Bundled Codex gpt-5.5 metadata:"
  if command -v "$codex_command" >/dev/null 2>&1; then
    "$codex_command" debug models --bundled | jq '.models[] | select(.slug=="gpt-5.5") | {slug,context_window,max_context_window,effective_context_window_percent}'
  else
    echo "  skipped: $codex_command not installed"
  fi
  echo
  echo "Active native context overrides:"
  rg -n '^[[:space:]]*(model_catalog_json|model_context_window)[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null || echo "  none"
  echo
  echo "Latest recorded native Codex session window:"
  ai_litellm_context_probe_latest_codex_session 2>/dev/null || echo "  unknown"
  echo "  note: this is historical session evidence; fresh sessions follow the active metadata above."
  if [[ "$1" == "codex-app-oauth" ]]; then
    echo
    echo "Note: Codex App GUI startup is not invoked by this probe; this row uses shared native config plus local session evidence."
  fi
}

ai_litellm_context_litellm_surfaces() {
  [[ -d "$AI_LITELLM_HARNESSES_DIR" ]] || return 0
  node -e '
const fs = require("fs");
const path = require("path");
const dir = process.argv[1];
for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".json") && name !== "schema.json").sort()) {
  const descriptor = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
  const context = descriptor.adapterConfig?.context || {};
  if (context.enabled === false) continue;
  const harness = descriptor.name || path.basename(file, ".json");
  console.log(context.surface || `${harness}-litellm`);
}
' "$AI_LITELLM_HARNESSES_DIR"
}

ai_litellm_context_runtime_surfaces() {
  local runtime
  for runtime in "${(@f)$(ai_litellm_runtime_names 2>/dev/null)}"; do
    [[ -n "$runtime" ]] && printf '%s-runtime\n' "$runtime"
  done
}

ai_litellm_context_surfaces() {
  printf '%s\n' codex-app-oauth codex-cli-oauth codex-cli-api
  ai_litellm_context_litellm_surfaces
  printf '%s\n' claude-code-native
  ai_litellm_context_runtime_surfaces
}

ai_litellm_context_surface_default_model() {
  local surface="$1"
  [[ -d "$AI_LITELLM_HARNESSES_DIR" ]] || return 1
  node -e '
const fs = require("fs");
const path = require("path");
const [dir, targetSurface] = process.argv.slice(1);
const readJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { return {}; }
};
for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".json") && name !== "schema.json").sort()) {
  const descriptor = readJson(path.join(dir, file));
  const context = descriptor.adapterConfig?.context || {};
  if (context.enabled === false) continue;
  const harness = descriptor.name || path.basename(file, ".json");
  const surface = context.surface || `${harness}-litellm`;
  if (surface !== targetSurface) continue;
  const models = descriptor.models || {};
  let model = "";
  if (models.mode === "tier-aliases") {
    const settings = readJson(descriptor.paths?.settings || "");
    const tier = settings.default || (models.tiers || [])[0] || "";
    model = (settings.aliases || {})[tier] || tier;
  } else {
    model = models.default || models.small || "";
  }
  if (model) {
    console.log(model);
    process.exit(0);
  }
}
process.exit(1);
' "$AI_LITELLM_HARNESSES_DIR" "$surface"
}

ai_litellm_context_probe_litellm_surface() {
  local surface="$1"
  echo "Surface: $surface"
  ai_litellm_context_matrix "$surface"
  echo
  if ai_litellm_health; then
    echo "Running proxy metadata:"
    local default_model
    default_model="$(ai_litellm_context_surface_default_model "$surface" 2>/dev/null || true)"
    if [[ -n "$default_model" ]]; then
      ai_litellm_route_info "$default_model"
    else
      ai_litellm_route_info
    fi
  else
    echo "Running proxy metadata: unavailable (proxy not reachable; not auto-starting for read-only probe)"
  fi
}

ai_litellm_context_probe_runtime_surface() {
  local surface="$1"
  local runtime="${surface%-runtime}"
  echo "Surface: $surface"
  ai_litellm_context_matrix "$surface"
  echo
  ai_litellm_runtime_status "$runtime"
  echo
  local api_base
  api_base="$(ai_litellm_runtime_field "$runtime" apiBase 2>/dev/null || true)"
  echo "Runtime /models:"
  [[ -n "$api_base" ]] && curl --max-time 3 -fsS "$api_base/models" 2>/dev/null \
    | jq '(.data // .models // [])[]? | {id:(.id // .model // .name), max_model_len, max_context_window, max_tokens}' \
    || echo "  not reachable"
}

ai_litellm_context_probe() {
  local surface="$1"
  if [[ -z "$surface" ]]; then
    echo "Usage: ai-litellm context probe <surface|all>" >&2
    echo "Surfaces: $(ai_litellm_context_surfaces | paste -sd ' ' -)" >&2
    return 1
  fi

  case "$surface" in
    all)
      local item failed=0
      for item in "${(@f)$(ai_litellm_context_surfaces)}"; do
        ai_litellm_context_probe "$item" || failed=1
        echo
      done
      return $failed
      ;;
    codex-app-oauth|codex-cli-oauth)
      ai_litellm_context_probe_codex_native "$surface"
      ;;
    codex-cli-api)
      echo "Surface: codex-cli-api"
      echo "Official API budget: gpt-5.5 context=1050000 output=128000"
      echo "Local state: API-key lane is not active unless $HOME/.codex/auth.json auth_mode is api-key."
      [[ -f "$HOME/.codex/auth.json" ]] && jq '{auth_mode, has_api_key:(.OPENAI_API_KEY!=null and .OPENAI_API_KEY!=""), has_tokens:(.tokens!=null)}' "$HOME/.codex/auth.json"
      ;;
    codex-litellm|claude-litellm|goose-litellm|opencode-litellm)
      ai_litellm_context_probe_litellm_surface "$surface"
      ;;
    claude-code-native)
      echo "Surface: claude-code-native"
      [[ -f "$HOME/.claude/settings.json" ]] && jq '{model, effortLevel}' "$HOME/.claude/settings.json" || echo "  missing $HOME/.claude/settings.json"
      echo "Observed session window: unknown (Claude Code native is not launched by this probe)"
      ;;
    *)
      if ai_litellm_context_litellm_surfaces | grep -Fx -- "$surface" >/dev/null; then
        ai_litellm_context_probe_litellm_surface "$surface"
      elif [[ "$surface" == *-runtime ]] && ai_litellm_runtime_names 2>/dev/null | grep -Fx -- "${surface%-runtime}" >/dev/null; then
        ai_litellm_context_probe_runtime_surface "$surface"
      else
        echo "Unknown context surface: $surface" >&2
        return 1
      fi
      ;;
  esac
}

ai_litellm_context_doctor_check() {
  local label="$1"
  shift
  if "$@"; then
    echo "ok   $label"
    return 0
  fi
  echo "fail $label"
  return 1
}

ai_litellm_context_doctor_warn() {
  echo "warn $1"
}

ai_litellm_context_native_no_override() {
  ! rg -q '^[[:space:]]*(model_catalog_json|model_context_window)[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null
}

ai_litellm_context_no_long_artifacts() {
  [[ ! -e "$HOME/.codex/api-long.config.toml" &&
     ! -e "$HOME/.codex/model-catalog-api-long.json" &&
     ! -e "$HOME/.codex/model-catalog-codex-safe.json" &&
     ! -e "$HOME/.codex/model-catalog-local.json" ]]
}

ai_litellm_context_codex_matches_bundled() {
  local active bundled codex_command
  codex_command="$(ai_litellm_harness_json codex command 2>/dev/null || printf 'codex')"
  command -v "$codex_command" >/dev/null 2>&1 || return 0
  active="$("$codex_command" debug models | jq -r '.models[] | select(.slug=="gpt-5.5") | [.context_window,.max_context_window,.effective_context_window_percent] | @tsv' 2>/dev/null)" || return 1
  bundled="$("$codex_command" debug models --bundled | jq -r '.models[] | select(.slug=="gpt-5.5") | [.context_window,.max_context_window,.effective_context_window_percent] | @tsv' 2>/dev/null)" || return 1
  [[ -n "$active" && "$active" == "$bundled" ]]
}

ai_litellm_context_pre_call_enabled() {
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
exit(config.dig("router_settings", "enable_pre_call_checks") == true ? 0 : 1)
' "$AI_LITELLM_CONFIG"
}

ai_litellm_context_claude_reservations_ok() {
  ai_litellm_harness_descriptor claude >/dev/null 2>&1 || return 0
  [[ "$(ai_litellm_harness_json claude adapter 2>/dev/null || true)" == "claude-code" ]] || return 0
  ai_litellm_harness_json claude adapterConfig.outputReservation.default >/dev/null 2>&1 || {
    echo "Claude descriptor is missing adapterConfig.outputReservation.default" >&2
    return 1
  }

  local settings
  settings="$(ai_litellm_harness_json claude paths.settings 2>/dev/null)" || return 1

  local failed=0 tier model budget reservation effective minimum context capability headroom
  for tier in "${(@f)$(ai_litellm_harness_json_array claude models.tiers 2>/dev/null)}"; do
    [[ -n "$tier" ]] || continue
    model="$(ai_litellm_json_file "$settings" "aliases.$tier" 2>/dev/null || true)"
    if [[ -z "$model" ]]; then
      echo "Claude tier has no alias: $tier" >&2
      failed=1
      continue
    fi

    budget="$(ai_litellm_harness_output_budget claude "$tier" "$model" 2>/dev/null || true)"
    if [[ -z "$budget" ]]; then
      echo "Claude tier has no output budget: $tier -> $model" >&2
      failed=1
      continue
    fi

    reservation="$(print -r -- "$budget" | jq -r '.reservation // 0')"
    effective="$(print -r -- "$budget" | jq -r '.effectiveInput // 0')"
    minimum="$(print -r -- "$budget" | jq -r '.minimumInput // 32768')"
    context="$(print -r -- "$budget" | jq -r '.context // "-"')"
    capability="$(print -r -- "$budget" | jq -r '.capability // "-"')"
    headroom="$(print -r -- "$budget" | jq -r '.tokenizerHeadroom // 0')"

    if (( ${reservation:-0} <= 0 )); then
      echo "Claude tier output reservation is not positive: $tier -> $model reservation=$reservation" >&2
      failed=1
    fi
    if (( ${effective:-0} < ${minimum:-32768} )); then
      echo "Claude tier input budget below minimum: $tier -> $model context=$context capability=$capability reservation=$reservation headroom=$headroom effective_input=$effective minimum=$minimum" >&2
      failed=1
    fi
  done

  return $failed
}

ai_litellm_context_harness_reservations_ok() {
  [[ -d "$AI_LITELLM_HARNESSES_DIR" ]] || return 0
  ruby -rjson -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
harness_dir = ARGV[1]
registry = {}
Array(config["model_list"]).each { |e| registry[e["model_name"]] = e if e["model_name"] }

def read_json(path)
  JSON.parse(File.read(path))
rescue
  {}
end

def positive_int(value)
  n = Integer(value)
  n.positive? ? n : nil
rescue
  nil
end

def selections(descriptor, registry)
  models = descriptor["models"] || {}
  settings = read_json(descriptor.dig("paths", "settings"))
  aliases = settings["aliases"] || {}
  out = []
  if models["mode"] == "tier-aliases"
    tiers = Array(models["tiers"])
    default = settings["default"] || tiers.first
    out << [default, aliases[default] || default] if default
    tiers.each { |tier| out << [tier, aliases[tier]] if aliases[tier] }
  else
    out << ["default", models["default"]] if models["default"]
    out << ["small", models["small"]] if models["small"]
    Array(aliases.values).uniq.each { |model| out << [model, model] if model }
    Array(models["localCatalogEntries"]).each do |entry|
      model = entry["slug"]
      out << [model, model] if model
    end
  end
  out.uniq.select { |_selection, model| model && registry.key?(model) }
end

def output_budget(policy, selection, model, ctx, out)
  pick = nil
  [
    ["perSelection.#{selection}", policy.dig("perSelection", selection)],
    ["perTier.#{selection}", policy.dig("perTier", selection)],
    ["perModel.#{model}", policy.dig("perModel", model)],
    ["default", policy["default"]]
  ].each do |source, value|
    n = positive_int(value)
    if n
      pick = [source, n]
      break
    end
  end
  capability = positive_int(out)
  return nil unless pick || capability
  source, reservation = pick || ["capability-clamped-default", [capability, 32000].compact.min]
  context = positive_int(ctx)
  headroom = positive_int(policy["tokenizerHeadroom"]) || 0
  minimum_input = positive_int(policy["minimumInput"]) || 32768
  reservation = capability if capability && reservation > capability
  if context
    headroom = [headroom, (context * 0.1).floor].min
    minimum_input = [minimum_input, [1, (context * 0.5).floor].max].min
    max_reservation = context - headroom - minimum_input
    if max_reservation < 1
      reservation = 1
      headroom = [0, context - minimum_input - reservation].max
    elsif reservation > max_reservation
      reservation = max_reservation
    end
  end
  effective = context ? [0, context - reservation - headroom].max : nil
  {reservation: reservation, effective: effective, minimum: minimum_input, context: context, headroom: headroom, capability: capability}
end

errors = []
Dir[File.join(harness_dir, "*.json")].sort.each do |path|
  next if File.basename(path) == "schema.json"
  descriptor = read_json(path)
  policy = descriptor.dig("adapterConfig", "outputReservation") || {}
  next if policy.empty?
  harness = descriptor["name"] || File.basename(path, ".json")
  selections(descriptor, registry).each do |selection, model|
    mi = registry.dig(model, "model_info") || {}
    budget = output_budget(policy, selection, model, mi["max_input_tokens"], mi["max_output_tokens"])
    if budget.nil? || budget[:reservation].to_i <= 0
      errors << "#{harness}/#{selection}->#{model}: reservation missing or non-positive"
      next
    end
    if budget[:effective].to_i < budget[:minimum].to_i
      errors << "#{harness}/#{selection}->#{model}: effective_input=#{budget[:effective]} minimum=#{budget[:minimum]} context=#{budget[:context]} reservation=#{budget[:reservation]} headroom=#{budget[:headroom]} capability=#{budget[:capability]}"
    end
  end
end

if errors.any?
  errors.each { |e| warn e }
  exit 1
end
' "$AI_LITELLM_CONFIG" "$AI_LITELLM_HARNESSES_DIR"
}

ai_litellm_context_warn_opencode_output_cap() {
  local config
  config="$(ai_litellm_harness_json opencode paths.config 2>/dev/null || true)"
  [[ -n "$config" && -f "$config" ]] || return 0
  ai_litellm_harness_json opencode adapterConfig.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX >/dev/null 2>&1 && return 0
  node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const provider = process.argv[2] || "litellm";
const models = cfg.provider?.[provider]?.models || {};
const high = Object.entries(models)
  .filter(([, m]) => Number(m.limit?.output || 0) > 32000)
  .map(([name, m]) => `${name}:${m.limit.output}`);
if (high.length && !process.env.OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX) {
  console.log(`OpenCode outputs above 32000 may be clamped unless OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX is set: ${high.join(", ")}`);
}
' "$config" "$(ai_litellm_harness_json opencode provider.name 2>/dev/null || printf 'litellm')" | while IFS= read -r line; do
    [[ -n "$line" ]] && ai_litellm_context_doctor_warn "$line"
  done
}

ai_litellm_context_warn_goose_scope() {
  local descriptor
  descriptor="$(ai_litellm_harness_descriptor goose 2>/dev/null)" || return 0
  node -e '
const fs = require("fs");
const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const env = d.adapterConfig?.env || {};
if (env.GOOSE_CONTEXT_LIMIT && !env.GOOSE_MAX_TOKENS) {
  console.log("Goose descriptor injects context without GOOSE_MAX_TOKENS output reservation.");
}
' "$descriptor" | while IFS= read -r line; do
    [[ -n "$line" ]] && ai_litellm_context_doctor_warn "$line"
  done
}

ai_litellm_context_warn_omlx_policy_cap() {
  ruby -rjson -ryaml -e '
settings_path, config_path = ARGV
settings = JSON.parse(File.read(settings_path)) rescue {}
config = (YAML.load_file(config_path, aliases: true) rescue YAML.load_file(config_path))
registry = {}
Array(config["model_list"]).each { |e| registry[e["model_name"]] = e if e["model_name"] }
Array(settings["runtimes"] || {}).each do |name, rt|
  next unless name == "omlx"
  Array(rt["expectedModels"]).each do |model|
    path = File.join(rt["modelsDir"].to_s, model, "config.json")
    next unless File.file?(path)
    payload = JSON.parse(File.read(path)) rescue {}
    runtime_ctx = payload.dig("text_config", "max_position_embeddings") || payload["max_position_embeddings"] || payload["max_model_len"]
    configured = registry.dig(model, "model_info", "max_input_tokens")
    if runtime_ctx && configured && configured.to_i < runtime_ctx.to_i
      puts "oMLX runtime/model context appears higher than LiteLLM policy cap for #{model}: runtime=#{runtime_ctx} configured=#{configured}"
    elsif runtime_ctx && configured && configured.to_i > runtime_ctx.to_i
      # Dangerous direction: LiteLLM admits prompts up to `configured`, but the
      # runtime physically caps at `runtime_ctx` and will reject the overflow.
      puts "LiteLLM policy cap exceeds oMLX runtime capacity for #{model}: configured=#{configured} runtime=#{runtime_ctx} (lower max_input_tokens to #{runtime_ctx})"
    end
  end
end
' "$AI_LITELLM_SETTINGS" "$AI_LITELLM_CONFIG" | while IFS= read -r line; do
    [[ -n "$line" ]] && ai_litellm_context_doctor_warn "$line"
  done
}

ai_litellm_context_warn_glm_output_source() {
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
Array(config["model_list"]).each do |e|
  next unless e.dig("litellm_params", "model").to_s == "openrouter/z-ai/glm-5.1"
  out = e.dig("model_info", "max_output_tokens")
  if out
    puts "GLM-5.1 output cap #{out} is local-configured; keep provider-declared confidence lower unless OpenRouter max_completion_tokens is observed."
  end
  break
end
' "$AI_LITELLM_CONFIG" | while IFS= read -r line; do
    [[ -n "$line" ]] && ai_litellm_context_doctor_warn "$line"
  done
}

ai_litellm_context_warn_output_clamp() {
  ruby -ryaml -e '
config = (YAML.load_file(ARGV[0], aliases: true) rescue YAML.load_file(ARGV[0]))
settings = config["litellm_settings"] || {}
has_modify = settings["modify_params"] == true
has_callback = Array(settings["callbacks"] || settings["success_callback"] || settings["failure_callback"]).any?
shared = Array(config["model_list"]).select do |entry|
  info = entry["model_info"] || {}
  ctx = info["max_input_tokens"].to_i
  out = info["max_output_tokens"].to_i
  ctx.positive? && out.positive? && ctx == out
end.map { |entry| entry["model_name"] }.compact.uniq
if shared.any? && !has_modify && !has_callback
  puts "shared-window routes have no gateway output clamp; harness reservation is the only output-reservation guard: #{shared.join(", ")}"
end
' "$AI_LITELLM_CONFIG" | while IFS= read -r line; do
    [[ -n "$line" ]] && ai_litellm_context_doctor_warn "$line"
  done
}

ai_litellm_context_descriptor_surfaces_ok() {
  [[ -d "$AI_LITELLM_HARNESSES_DIR" ]] || return 0
  node -e '
const fs = require("fs");
const path = require("path");
const dir = process.argv[1];
const seen = new Map();
const errors = [];
for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".json") && name !== "schema.json").sort()) {
  const descriptor = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
  const context = descriptor.adapterConfig?.context || {};
  if (context.enabled === false) continue;
  const harness = descriptor.name || path.basename(file, ".json");
  const surface = context.surface || `${harness}-litellm`;
  if (!surface) errors.push(`${harness}: context surface is empty`);
  if (seen.has(surface)) errors.push(`duplicate context surface ${surface}: ${seen.get(surface)} and ${harness}`);
  else seen.set(surface, harness);
}
if (errors.length) {
  for (const error of errors) console.error(error);
  process.exit(1);
}
' "$AI_LITELLM_HARNESSES_DIR"
}

ai_litellm_context_doctor() {
  local failed=0
  echo "ai-litellm context doctor"
  ai_litellm_context_doctor_check "native Codex has no active local context override" ai_litellm_context_native_no_override || failed=1
  ai_litellm_context_doctor_check "native Codex long-context artifacts are not active" ai_litellm_context_no_long_artifacts || failed=1
  ai_litellm_context_doctor_check "native Codex active gpt-5.5 catalog matches bundled catalog" ai_litellm_context_codex_matches_bundled || failed=1
  ai_litellm_context_doctor_check "LiteLLM pre-call context enforcement enabled" ai_litellm_context_pre_call_enabled || failed=1
  ai_litellm_context_doctor_check "harness context surfaces are unique" ai_litellm_context_descriptor_surfaces_ok || failed=1
  ai_litellm_context_doctor_check "harness configs match single-source limits" ai_litellm_doctor_limit_sync || failed=1
  ai_litellm_context_doctor_check "harness output reservations leave input budget" ai_litellm_context_harness_reservations_ok || failed=1
  ai_litellm_context_doctor_check "context matrix renders" ai_litellm_quiet ai_litellm_context_matrix || failed=1
  ai_litellm_context_warn_opencode_output_cap
  ai_litellm_context_warn_goose_scope
  ai_litellm_context_warn_omlx_policy_cap
  ai_litellm_context_warn_glm_output_source
  ai_litellm_context_warn_output_clamp
  return $failed
}

ai_litellm_deprecated() {
  echo "ai-litellm: '$1' is deprecated; use 'ai-litellm $2'" >&2
}

# ── Noun-verb sub-dispatchers ────────────────────────────────────────────────
ai_litellm_cmd_proxy() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    status|"") ai_litellm_status ;;
    start)     ai_litellm_start ;;
    stop)      ai_litellm_stop ;;
    restart)   ai_litellm_restart ;;
    logs)      ai_litellm_logs "$@" ;;
    doctor)    ai_litellm_doctor "$@" ;;
    *) echo "Usage: ai-litellm proxy status|start|stop|restart|logs [lines]|doctor [--probe-routes|--probe-model name|--runtime name]" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_harness() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    list|"") ai_litellm_harnesses ;;
    info)    ai_litellm_harness_info "$@" ;;
    launch)  ai_litellm_launch "$@" ;;
    reasoning)
      case "${1:-}" in
        set)   shift; ai_litellm_harness_reasoning_set "$@" ;;
        unset) shift; ai_litellm_harness_reasoning_unset "$@" ;;
        *)     ai_litellm_harness_reasoning_table "$@" ;;
      esac
      ;;
    *) echo "Usage: ai-litellm harness list|info <name>|launch <name> [model] [args...]|reasoning [name]|reasoning set <name> <effort>|reasoning unset <name>" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_runtime() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    list)      ai_litellm_runtime_names ;;
    status|"") ai_litellm_runtime_status "$@" ;;
    doctor)    ai_litellm_doctor_runtime "$@" ;;
    *) echo "Usage: ai-litellm runtime list|status [name]|doctor <name>" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_model() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    list|"")      ai_litellm_list ;;
    info)         ai_litellm_route_info "$@" ;;
    limits)       ai_litellm_limits_table "$@" ;;
    reasoning)
      case "${1:-}" in
        probe) shift; ai_litellm_model_reasoning_probe "$@" ;;
        set)   shift; ai_litellm_model_reasoning_set "$@" ;;
        unset) shift; ai_litellm_model_reasoning_unset "$@" ;;
        *)     ai_litellm_deprecated "model reasoning" "reasoning matrix"; ai_litellm_model_reasoning_table "$@" ;;
      esac
      ;;
    probe)        ai_litellm_probe_routes "$@" ;;
    capabilities) ai_litellm_capabilities ;;
    *) echo "Usage: ai-litellm model list|info [model]|limits [model]|reasoning probe <model> [effort]|reasoning set <model> <effort>|reasoning unset <model>|probe <model...>|capabilities" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_route() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    list|"") ai_litellm_route_info ;;
    info)    ai_litellm_route_info "$@" ;;
    probe)   ai_litellm_probe_routes "$@" ;;
    check)
      if (( $# == 0 )); then
        ai_litellm_probe_routes "${(@f)$(ai_litellm_model_names)}"
      else
        ai_litellm_probe_routes "$@"
      fi
      ;;
    *) echo "Usage: ai-litellm route list|info [model]|probe <model...>|check [model...]" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_key() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    status|"") ai_litellm_key_status ;;
    *) echo "Usage: ai-litellm key status" >&2; return 1 ;;
  esac
}

ai_litellm_cmd_context() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    matrix|"") ai_litellm_context_matrix "$@" ;;
    probe)     ai_litellm_context_probe "$@" ;;
    doctor)    ai_litellm_context_doctor "$@" ;;
    *) echo "Usage: ai-litellm context matrix [filter]|probe <surface|all>|doctor" >&2; return 1 ;;
  esac
}

ai_litellm_reasoning_doctor() {
  local failed=0
  echo "ai-litellm reasoning doctor"
  ai_litellm_doctor_check "reasoning matrix renders" ai_litellm_quiet ai_litellm_model_reasoning_table || failed=1
  ai_litellm_doctor_check "harness reasoning configs match descriptors" ai_litellm_doctor_reasoning_sync || failed=1
  ai_litellm_doctor_reasoning_capability_truth
  return $failed
}

ai_litellm_cmd_reasoning() {
  local verb="$1"; [[ $# -gt 0 ]] && shift
  case "$verb" in
    matrix|"") ai_litellm_model_reasoning_table "$@" ;;
    probe)     ai_litellm_model_reasoning_probe "$@" ;;
    doctor)    ai_litellm_reasoning_doctor "$@" ;;
    *) echo "Usage: ai-litellm reasoning matrix [model]|probe <model> [effort]|doctor" >&2; return 1 ;;
  esac
}

ai_litellm_usage() {
  cat <<'EOF'
Usage: ai-litellm <group> <verb> [args]

  Proxy:    ai-litellm proxy status|start|stop|restart|logs [lines]|doctor [opts]
  Harness:  ai-litellm harness list|info <name>|launch <name> [model] [args...]
            ai-litellm harness reasoning [name]
            ai-litellm harness reasoning set <name> <effort>
            ai-litellm harness reasoning unset <name>
  Runtime:  ai-litellm runtime list|status [name]|doctor <name>
  Model:    ai-litellm model list|info [model]|limits [model]|probe <model...>|capabilities
            ai-litellm model reasoning probe <model> [effort]
            ai-litellm model reasoning set <model> <effort>
            ai-litellm model reasoning unset <model>
  Effort:   OpenRouter none|minimal|low|medium|high|xhigh; Claude auto|low|medium|high|xhigh|max;
            Codex low|medium|high|xhigh; OpenCode auto|none|minimal|low|medium|high|max; Goose auto|none
  Route:    ai-litellm route list|info [model]|probe <model...>|check [model...]
  Context:  ai-litellm context matrix [filter]|probe <surface|all>|doctor
  Reason:   ai-litellm reasoning matrix [model]|probe <model> [effort]|doctor
  Key:      ai-litellm key status
  Sync:     ai-litellm sync          Regenerate derived configs + reload proxy from the single source
  Caps:     ai-litellm capabilities  Proxy + runtime capability summary

Flat forms (start, stop, status, route-info, harnesses, launch, ...) still work but
are deprecated in favor of the groups above.
EOF
}

ai_litellm() {
  local cmd="$1"; [[ $# -gt 0 ]] && shift
  case "$cmd" in
    -h|--help|"") ai_litellm_usage ;;

    # ── Canonical noun-verb groups ──
    proxy)        ai_litellm_cmd_proxy "$@" ;;
    harness)      ai_litellm_cmd_harness "$@" ;;
    runtime)      ai_litellm_cmd_runtime "$@" ;;
    model)        ai_litellm_cmd_model "$@" ;;
    route)        ai_litellm_cmd_route "$@" ;;
    context)      ai_litellm_cmd_context "$@" ;;
    reasoning)    ai_litellm_cmd_reasoning "$@" ;;
    key)          ai_litellm_cmd_key "$@" ;;
    sync|--sync)  ai_litellm_sync "$@" ;;
    capabilities|--capabilities) ai_litellm_capabilities ;;

    # ── Deprecated flat aliases (still work; warn + delegate) ──
    start|--start)               ai_litellm_deprecated start "proxy start"; ai_litellm_start ;;
    stop|--stop)                 ai_litellm_deprecated stop "proxy stop"; ai_litellm_stop ;;
    restart|--restart)           ai_litellm_deprecated restart "proxy restart"; ai_litellm_restart ;;
    status|--status)             ai_litellm_deprecated status "proxy status"; ai_litellm_status ;;
    logs|--logs)                 ai_litellm_deprecated logs "proxy logs"; ai_litellm_logs "$@" ;;
    doctor|--doctor)             ai_litellm_deprecated doctor "proxy doctor"; ai_litellm_doctor "$@" ;;
    list|--list)                 ai_litellm_deprecated list "model list"; ai_litellm_list ;;
    route-info|--route-info)     ai_litellm_deprecated route-info "route info"; ai_litellm_route_info "$@" ;;
    probe-route|--probe-route)   ai_litellm_deprecated probe-route "model probe"; ai_litellm_probe_routes "$@" ;;
    runtime-status|--runtime-status) ai_litellm_deprecated runtime-status "runtime status"; ai_litellm_runtime_status "$@" ;;
    harnesses|--harnesses)       ai_litellm_deprecated harnesses "harness list"; ai_litellm_harnesses ;;
    harness-info|--harness-info) ai_litellm_deprecated harness-info "harness info"; ai_litellm_harness_info "$@" ;;
    launch|--launch)             ai_litellm_deprecated launch "harness launch"; ai_litellm_launch "$@" ;;
    key-status|--key-status)     ai_litellm_deprecated key-status "key status"; ai_litellm_key_status ;;

    *)
      echo "Unknown ai-litellm command: $cmd" >&2
      ai_litellm_usage >&2
      return 1
      ;;
  esac
}

# Backward-compatible shared helper names.
_claude_litellm_source_env() { return 0; }
_claude_litellm_env_value() { ai_litellm_env_value "$@"; }
_claude_litellm_keychain_value() { ai_litellm_keychain_value "$@"; }
_claude_litellm_openrouter_key() { ai_litellm_openrouter_key "$@"; }
_claude_litellm_model_names() { ai_litellm_model_names "$@"; }
_claude_litellm_model_exists() { ai_litellm_model_exists "$@"; }
_claude_litellm_model_backend() { ai_litellm_model_backend "$@"; }
_claude_litellm_master_key() { ai_litellm_master_key "$@"; }
_claude_litellm_host() { ai_litellm_host "$@"; }
_claude_litellm_port() { ai_litellm_port "$@"; }
_claude_litellm_base_url() { ai_litellm_base_url "$@"; }
_claude_litellm_health() { ai_litellm_health "$@"; }
_claude_litellm_pid_running() { ai_litellm_pid_running "$@"; }

start-litellm() { ai_litellm_start "$@"; }
stop-litellm() { ai_litellm_stop "$@"; }
