#!/bin/bash
#
# Interactive driver for rclone's JSON configuration protocol.
#
# `rclone config create` normally answers backend questions with their
# defaults. iCloud's 2FA question has no default, so rclone submits a blank code
# immediately instead of waiting for the user. This driver explicitly presents
# each question and continues the saved authentication state with the answer.
#
# Sourced by commands that have already loaded omarchy-cloud-ui.sh.

_cloud_json_field() {
  python3 -c '
import json, sys
value = json.load(sys.stdin).get(sys.argv[1], "")
if value is None:
    value = ""
print(str(value).lower() if isinstance(value, bool) else value)
' "$1"
}

_cloud_json_option_field() {
  python3 -c '
import json, sys
option = json.load(sys.stdin).get("Option") or {}
value = option.get(sys.argv[1], "")
if value is None:
    value = ""
print(str(value).lower() if isinstance(value, bool) else value)
' "$1"
}

_cloud_json_option_examples() {
  python3 -c '
import json, sys
option = json.load(sys.stdin).get("Option") or {}
for example in option.get("Examples") or []:
    value = str(example.get("Value", ""))
    help_text = str(example.get("Help", "")).replace("\n", " ")
    label = f"{help_text} ({value})" if help_text and help_text != value else value
    print(f"{value}\t{label}")
'
}

# Usage: run_icloud_config REMOTE_NAME <rclone config create/update arguments>
run_icloud_config() {
  local remote_name="$1"
  shift

  local response
  response="$(rclone "$@" --non-interactive)" || return 1

  while true; do
    local state error option_name help_text required is_password exclusive
    if ! state="$(_cloud_json_field State <<<"$response" 2>/dev/null)"; then
      bad "rclone returned an unreadable iCloud authentication response."
      return 1
    fi
    error="$(_cloud_json_field Error <<<"$response")"
    [[ -n "$error" ]] && bad "$error"

    if [[ -z "$state" ]]; then
      [[ -z "$error" ]]
      return
    fi

    option_name="$(_cloud_json_option_field Name <<<"$response")"
    help_text="$(_cloud_json_option_field Help <<<"$response")"
    required="$(_cloud_json_option_field Required <<<"$response")"
    is_password="$(_cloud_json_option_field IsPassword <<<"$response")"
    exclusive="$(_cloud_json_option_field Exclusive <<<"$response")"
    if [[ -z "$option_name" ]]; then
      bad "rclone did not provide the next iCloud authentication question."
      return 1
    fi

    echo "$help_text"
    echo

    local answer=""
    if [[ "$exclusive" == "true" ]]; then
      local -a values=() labels=()
      local value label
      while IFS=$'\t' read -r value label; do
        values+=("$value")
        labels+=("$label")
      done < <(_cloud_json_option_examples <<<"$response")
      ((${#labels[@]} > 0)) || return 1

      local choice
      choice="$(printf '%s\n' "${labels[@]}" | gum choose --header "")" ||
        return 130
      local i
      for i in "${!labels[@]}"; do
        if [[ "${labels[$i]}" == "$choice" ]]; then
          answer="${values[$i]}"
          break
        fi
      done
    else
      local placeholder="$option_name"
      case "$option_name" in
        config_2fa)     placeholder="6-digit code or sms" ;;
        config_2fa_sms) placeholder="SMS verification code" ;;
      esac

      local -a input_args=(input --placeholder "$placeholder")
      [[ "$is_password" == "true" ]] && input_args+=(--password)
      while true; do
        answer="$(gum "${input_args[@]}")" || return 130
        [[ "$required" != "true" || -n "$answer" ]] && break
        bad "A response is required."
      done
    fi

    # The first step persisted the credentials, cookies and private auth
    # session. Continue against that remote so no password appears here.
    response="$(rclone config update "$remote_name" \
      --continue --state "$state" --result "$answer" --non-interactive)" ||
      return 1
  done
}
