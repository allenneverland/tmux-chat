#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

DOCKER_BIN="${DOCKER:-docker}"
ENV_FILE="${PUSH_SERVER_ENV_FILE:-ops/deploy/push-server.env}"
SAMPLE_FILE="ops/deploy/push-server.env.sample"
IMAGE="${PUSH_SERVER_IMAGE:-reattach-push-server:local}"
CONTAINER_NAME="${PUSH_SERVER_CONTAINER_NAME:-reattach-push-server}"
HOST_DATA_DIR="${PUSH_SERVER_HOST_DATA_DIR:-/var/lib/reattach/push-server}"
HOST_PORT="${PUSH_SERVER_HOST_PORT:-8790}"
CONTAINER_PORT="${PUSH_SERVER_CONTAINER_PORT:-8790}"

required_keys=(
  PUSH_SERVER_PUBLIC_BASE_URL
  PUSH_SERVER_COMPAT_NOTIFY_TOKEN
  APNS_KEY_BASE64
  APNS_KEY_ID
  APNS_TEAM_ID
  APNS_BUNDLE_ID
)

ensure_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    mkdir -p "$(dirname "${ENV_FILE}")"
    cp "${SAMPLE_FILE}" "${ENV_FILE}"
    echo "Created ${ENV_FILE} from sample."
  fi
}

get_env_value() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    echo ""
    return
  fi
  echo "${line#*=}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q -E "^${key}=" "${ENV_FILE}"; then
    sed -i.bak -E "s|^${key}=.*$|${key}=${value}|" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

is_placeholder() {
  local v="$1"
  [[ -z "${v}" ]] && return 0
  [[ "${v}" == *"REPLACE_WITH"* ]] && return 0
  [[ "${v}" == *"CHANGE_ME"* ]] && return 0
  [[ "${v}" == "..." ]] && return 0
  return 1
}

prompt_text() {
  local key="$1"
  local label="$2"
  local current
  current="$(get_env_value "${key}")"
  local display_default=""
  if ! is_placeholder "${current}"; then
    display_default="${current}"
  fi

  local input=""
  if [[ -n "${display_default}" ]]; then
    read -r -p "${label} [直接 Enter 保留現值]: " input
    if [[ -z "${input}" ]]; then
      input="${display_default}"
    fi
  else
    while [[ -z "${input}" ]]; do
      read -r -p "${label}: " input
    done
  fi
  set_env_value "${key}" "${input}"
}

prompt_secret() {
  local key="$1"
  local label="$2"
  local current
  current="$(get_env_value "${key}")"

  local has_existing="0"
  if ! is_placeholder "${current}"; then
    has_existing="1"
  fi

  local input=""
  if [[ "${has_existing}" == "1" ]]; then
    read -r -s -p "${label} [直接 Enter 保留現值]: " input
    echo
    if [[ -z "${input}" ]]; then
      input="${current}"
    fi
  else
    while [[ -z "${input}" ]]; do
      read -r -s -p "${label}: " input
      echo
    done
  fi
  set_env_value "${key}" "${input}"
}

prompt_apns_key_base64() {
  local current
  current="$(get_env_value "APNS_KEY_BASE64")"
  local has_existing="0"
  if ! is_placeholder "${current}"; then
    has_existing="1"
  fi

  echo
  echo "APNS_KEY_BASE64 設定方式："
  echo "1) 提供 .p8 檔案路徑（自動轉 base64）"
  echo "2) 直接貼上 APNS_KEY_BASE64"
  if [[ "${has_existing}" == "1" ]]; then
    echo "3) 保留現有值"
  fi

  local choice=""
  while :; do
    if [[ "${has_existing}" == "1" ]]; then
      read -r -p "請選擇 [1/2/3]: " choice
      [[ "${choice}" =~ ^[123]$ ]] && break
    else
      read -r -p "請選擇 [1/2]: " choice
      [[ "${choice}" =~ ^[12]$ ]] && break
    fi
  done

  case "${choice}" in
    1)
      local p8_path=""
      while :; do
        read -r -p ".p8 檔案路徑: " p8_path
        [[ -n "${p8_path}" && -f "${p8_path}" ]] && break
        echo "找不到檔案，請重新輸入。"
      done
      local encoded
      encoded="$(base64 < "${p8_path}" | tr -d '\n')"
      set_env_value "APNS_KEY_BASE64" "${encoded}"
      ;;
    2)
      prompt_secret "APNS_KEY_BASE64" "貼上 APNS_KEY_BASE64"
      ;;
    3)
      ;;
  esac
}

validate_required() {
  local key
  for key in "${required_keys[@]}"; do
    local v
    v="$(get_env_value "${key}")"
    if is_placeholder "${v}"; then
      echo "缺少必要設定：${key}" >&2
      return 1
    fi
  done
}

run_deploy() {
  echo
  echo "Building push-server image: ${IMAGE}"
  "${DOCKER_BIN}" build -f push-server/Dockerfile --target runtime -t "${IMAGE}" .

  mkdir -p "${HOST_DATA_DIR}"
  "${DOCKER_BIN}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  echo "Starting container: ${CONTAINER_NAME}"
  "${DOCKER_BIN}" run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    -v "${HOST_DATA_DIR}:/var/lib/reattach/push-server" \
    --env-file "${ENV_FILE}" \
    -e PUSH_SERVER_DATA_DIR=/var/lib/reattach/push-server \
    -e PUSH_SERVER_BIND_ADDR=0.0.0.0 \
    -e PUSH_SERVER_PORT="${CONTAINER_PORT}" \
    "${IMAGE}" >/dev/null

  echo
  echo "Deployed ${CONTAINER_NAME} on port ${HOST_PORT}"
  "${DOCKER_BIN}" ps --filter "name=^/${CONTAINER_NAME}$"
}

main() {
  ensure_env_file

  echo "=== push-server interactive deploy ==="
  echo "設定檔：${ENV_FILE}"
  echo

  prompt_text "PUSH_SERVER_PUBLIC_BASE_URL" "Push Server 對外 URL（例：https://push.example.com）"
  prompt_secret "PUSH_SERVER_COMPAT_NOTIFY_TOKEN" "PUSH_SERVER_COMPAT_NOTIFY_TOKEN"
  prompt_apns_key_base64
  prompt_text "APNS_KEY_ID" "APNS_KEY_ID"
  prompt_text "APNS_TEAM_ID" "APNS_TEAM_ID"
  prompt_text "APNS_BUNDLE_ID" "APNS_BUNDLE_ID"

  validate_required
  run_deploy
}

main "$@"
