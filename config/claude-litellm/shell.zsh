# Claude Code through the shared local LiteLLM gateway.

if ! typeset -f ai_litellm >/dev/null 2>&1 && [[ -f "${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/config/ai-litellm/lib.zsh" ]]; then
  source "${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/config/ai-litellm/lib.zsh"
elif ! typeset -f ai_litellm >/dev/null 2>&1 && [[ -f "$HOME/.config/ai-litellm/lib.zsh" ]]; then
  source "$HOME/.config/ai-litellm/lib.zsh"
fi

export CLAUDE_LITELLM_HARNESS="${CLAUDE_LITELLM_HARNESS:-claude}"
export CLAUDE_LITELLM_HOME="${CLAUDE_LITELLM_HOME:-$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" paths.home 2>/dev/null || printf "${AI_LITELLM_STATE_HOME:-${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}/state}/claude-litellm")}"
export CLAUDE_LITELLM_SETTINGS="${CLAUDE_LITELLM_SETTINGS:-$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" paths.settings 2>/dev/null || printf "$CLAUDE_LITELLM_HOME/settings.json")}"
export CLAUDE_LITELLM_CLAUDE_CONFIG="${CLAUDE_LITELLM_CLAUDE_CONFIG:-$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" paths.configDir 2>/dev/null || printf "$CLAUDE_LITELLM_HOME/claude-config")}"
export CLAUDE_LITELLM_SETTINGS_ARG="${CLAUDE_LITELLM_SETTINGS_ARG:-$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" paths.settingsArg 2>/dev/null || printf "$CLAUDE_LITELLM_CLAUDE_CONFIG/settings.json")}"
export CLAUDE_LITELLM_CONFIG="${CLAUDE_LITELLM_CONFIG:-$AI_LITELLM_CONFIG}"

_claude_litellm_json() {
  ai_litellm_json_file "$CLAUDE_LITELLM_SETTINGS" "$1"
}

_claude_litellm_tiers() {
  ai_litellm_harness_json_array "$CLAUDE_LITELLM_HARNESS" models.tiers 2>/dev/null || {
    printf 'opus\nsonnet\nhaiku\n'
  }
}

_claude_litellm_is_tier() {
  local candidate="$1"
  _claude_litellm_tiers | grep -Fx -- "$candidate" >/dev/null
}

_claude_litellm_target_model_for_request() {
  local requested="$1"
  if [[ -z "$requested" ]]; then
    requested="$(_claude_litellm_json default 2>/dev/null || printf 'sonnet')"
  fi

  if _claude_litellm_is_tier "$requested"; then
    local target_model
    target_model="$(_claude_litellm_json "aliases.$requested" 2>/dev/null)" || return 1
    ai_litellm_model_exists "$target_model" || return 1
    printf '%s\n' "$target_model"
    return 0
  fi

  ai_litellm_model_exists "$requested" || return 1
  printf '%s\n' "$requested"
}

_claude_litellm_resolve_model_arg() {
  local requested="$1"
  if [[ -z "$requested" ]]; then
    requested="$(_claude_litellm_json default 2>/dev/null || printf 'sonnet')"
  fi

  if _claude_litellm_is_tier "$requested"; then
    local target_model
    target_model="$(_claude_litellm_json "aliases.$requested" 2>/dev/null)" || return 1
    ai_litellm_model_exists "$target_model" || return 1
    printf '%s\n' "$requested"
    return 0
  fi

  ai_litellm_model_exists "$requested" || return 1
  printf '%s\n' "$requested"
}

claude-litellm-start() {
  ai_litellm_start "$@"
}

claude-litellm-stop() {
  ai_litellm_stop "$@"
}

claude-litellm-restart() {
  ai_litellm_restart "$@"
}

claude-litellm-status() {
  echo "Claude settings: $CLAUDE_LITELLM_SETTINGS"
  echo "Claude config:   $CLAUDE_LITELLM_CLAUDE_CONFIG"
  ai_litellm_status
}

claude-litellm-list() {
  echo "Claude aliases:"
  echo "  default -> $(_claude_litellm_json default 2>/dev/null || printf 'sonnet')"
  local tier
  _claude_litellm_tiers | while IFS= read -r tier; do
    printf '  %-7s -> %s\n' "$tier" "$(_claude_litellm_json "aliases.$tier" 2>/dev/null || true)"
  done
  echo
  ai_litellm_list
}

claude-litellm() {
  if ! typeset -f ai_litellm >/dev/null 2>&1; then
    echo "Missing shared LiteLLM library: $AI_LITELLM_CONFIG_HOME/ai-litellm/lib.zsh" >&2
    return 1
  fi

  case "$1" in
    -h|--help)
      echo "Usage: claude-litellm [opus|sonnet|haiku|model_name] [claude args...]"
      echo "       claude-litellm --list|--status   (harness-specific info)"
      echo "Reasoning defaults: ai-litellm harness reasoning [set|unset] claude"
      echo "Proxy lifecycle moved to: ai-litellm proxy start|stop|restart|logs|doctor"
      return 0
      ;;
    --list)
      claude-litellm-list
      return $?
      ;;
    --status)
      claude-litellm-status
      return $?
      ;;
    --start)
      echo "claude-litellm --start is deprecated; use 'ai-litellm proxy start'" >&2
      claude-litellm-start
      return $?
      ;;
    --stop)
      echo "claude-litellm --stop is deprecated; use 'ai-litellm proxy stop'" >&2
      claude-litellm-stop
      return $?
      ;;
    --restart)
      echo "claude-litellm --restart is deprecated; use 'ai-litellm proxy restart'" >&2
      claude-litellm-restart
      return $?
      ;;
    --logs)
      echo "claude-litellm --logs is deprecated; use 'ai-litellm proxy logs'" >&2
      shift
      ai_litellm_logs "$@"
      return $?
      ;;
    --doctor)
      echo "claude-litellm --doctor is deprecated; use 'ai-litellm proxy doctor'" >&2
      shift
      ai_litellm_doctor "$@"
      return $?
      ;;
  esac

  local requested=""
  if [[ -n "${1:-}" && "$1" != -* ]] && _claude_litellm_resolve_model_arg "$1" >/dev/null 2>&1; then
    requested="$1"
    shift
  fi

  local claude_model_arg
  local target_model
  target_model="$(_claude_litellm_target_model_for_request "$requested")" || {
    echo "Unknown claude-litellm alias or LiteLLM model_name: ${requested:-$(_claude_litellm_json default 2>/dev/null || printf 'sonnet')}" >&2
    return 1
  }
  claude_model_arg="$(_claude_litellm_resolve_model_arg "$requested")" || {
    echo "Unknown claude-litellm alias or LiteLLM model_name: ${requested:-$(_claude_litellm_json default 2>/dev/null || printf 'sonnet')}" >&2
    return 1
  }

  ai_litellm_model_runtime_ready "$target_model" || return $?
  ai_litellm_start >/dev/null || return $?
  mkdir -p "$CLAUDE_LITELLM_CLAUDE_CONFIG"

  local master_key
  master_key="$(ai_litellm_master_key)"

  if [[ -z "$master_key" ]]; then
    echo "Missing LiteLLM master key." >&2
    return 1
  fi

  local claude_command
  claude_command="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" command 2>/dev/null || printf 'claude')"

  local base_url_env auth_env discovery_env isolation_env tier_model_prefix tier_display_prefix
  local auto_compact_window_env max_output_tokens_env
  base_url_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.baseUrlEnv 2>/dev/null || printf 'ANTHROPIC_BASE_URL')"
  auth_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" provider.auth.env 2>/dev/null || printf 'ANTHROPIC_AUTH_TOKEN')"
  discovery_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.discoveryEnv 2>/dev/null || printf 'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY')"
  isolation_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" isolation.env 2>/dev/null || printf 'CLAUDE_CONFIG_DIR')"
  tier_model_prefix="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.tierModelEnvPrefix 2>/dev/null || printf 'ANTHROPIC_DEFAULT')"
  tier_display_prefix="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.tierDisplayNameEnvPrefix 2>/dev/null || printf 'ANTHROPIC_DEFAULT')"
  auto_compact_window_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.autoCompactWindowEnv 2>/dev/null || printf 'CLAUDE_CODE_AUTO_COMPACT_WINDOW')"
  max_output_tokens_env="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.maxOutputTokensEnv 2>/dev/null || printf 'CLAUDE_CODE_MAX_OUTPUT_TOKENS')"

  local -a env_assignments
  env_assignments=(
    "$base_url_env=$(ai_litellm_harness_template_json "$CLAUDE_LITELLM_HARNESS" provider.baseUrl 2>/dev/null || ai_litellm_base_url)"
    "$auth_env=$master_key"
    "$discovery_env=1"
    "$isolation_env=$CLAUDE_LITELLM_CLAUDE_CONFIG"
  )

  local tier tier_upper tier_model tier_display
  local -a tiers
  tiers=("${(@f)$(_claude_litellm_tiers)}")
  for tier in "${tiers[@]}"; do
    tier_upper="${tier:u}"
    tier_model="$(_claude_litellm_json "aliases.$tier" 2>/dev/null || true)"
    tier_display="$(_claude_litellm_json "displayNames.$tier" 2>/dev/null || printf '%s via LiteLLM' "$tier_upper")"
    env_assignments+=(
      "${tier_model_prefix}_${tier_upper}_MODEL=$tier_model"
      "${tier_display_prefix}_${tier_upper}_MODEL_NAME=$tier_display"
    )
  done

  # Claude Code exposes process-global knobs for compact threshold and request
  # max_tokens. Shared-window providers count input + reserved output together,
  # so we inject a small reservation rather than the model's output capability.
  local active_budget active_effective_input active_reservation
  active_budget="$(ai_litellm_harness_output_budget "$CLAUDE_LITELLM_HARNESS" "$claude_model_arg" "$target_model" 2>/dev/null || true)"
  if [[ -n "$active_budget" ]]; then
    active_effective_input="$(print -r -- "$active_budget" | jq -r '.effectiveInput // empty')"
    active_reservation="$(print -r -- "$active_budget" | jq -r '.reservation // empty')"
    [[ -n "$active_effective_input" ]] && env_assignments+=("${auto_compact_window_env}=$active_effective_input")
    [[ -n "$active_reservation" ]] && env_assignments+=("${max_output_tokens_env}=$active_reservation")
  fi

  local harness_effort
  local -a claude_extra_args
  harness_effort="$(ai_litellm_harness_json "$CLAUDE_LITELLM_HARNESS" adapterConfig.reasoning.effort 2>/dev/null || true)"
  if [[ -n "$harness_effort" && "$harness_effort" != "auto" && "$harness_effort" != "none" ]]; then
    if ! ai_litellm_cli_arg_present --effort "$@"; then
      claude_extra_args=(--effort "$harness_effort")
    fi
  fi

  ai_litellm_harness_exec_env "$CLAUDE_LITELLM_HARNESS" "${env_assignments[@]}" -- \
    "$claude_command" --settings "$CLAUDE_LITELLM_SETTINGS_ARG" --model "$claude_model_arg" "${claude_extra_args[@]}" "$@"
}

claude-via-litellm() {
  claude-litellm "$@"
}
