#!/bin/bash
set -euo pipefail
set +x

NS_HEADER=()
if [[ -n "${SBERCA_NAMESPACE:-}" ]]; then
  NS_HEADER=(-H "X-Vault-Namespace: ${SBERCA_NAMESPACE}")
fi

REQ_URL="${SBERCA_URL}/v1/${SBERCA_API_PATH}"

echo "[SBERCA-DIAG] ========================================" >&2
echo "[SBERCA-DIAG] Подготовка запроса к SberCA fetch" >&2
echo "[SBERCA-DIAG] namespace: ${SBERCA_NAMESPACE:-<empty>}" >&2
echo "[SBERCA-DIAG] api_path: ${SBERCA_API_PATH}" >&2
echo "[SBERCA-DIAG] request_url: ${REQ_URL}" >&2
echo "[SBERCA-DIAG] payload_json: ${SBERCA_REQUEST_PAYLOAD}" >&2
echo "[SBERCA-DIAG] curl шаблон: curl -X POST <REQ_URL> -H 'X-Vault-Token: ***' -H 'X-Vault-Namespace: ...' -H 'Content-Type: application/json' --data '<payload>'" >&2
echo "[SBERCA-DIAG] ========================================" >&2

CAP_PAYLOAD=$(printf '{"paths":["%s"]}' "${SBERCA_API_PATH}")
CAP_RESP_FILE="$(mktemp)"
CAP_HTTP_CODE=$(curl -sS -o "${CAP_RESP_FILE}" -w "%{http_code}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${NS_HEADER[@]}" \
  -H "Content-Type: application/json" \
  --request POST \
  --data "${CAP_PAYLOAD}" \
  "${SBERCA_URL}/v1/sys/capabilities-self" || true)

echo "[SBERCA-DIAG] capabilities-self http_code: ${CAP_HTTP_CODE}" >&2
echo "[SBERCA-DIAG] capabilities-self response: $(cat "${CAP_RESP_FILE}" 2>/dev/null || true)" >&2
rm -f "${CAP_RESP_FILE}"

FETCH_RESP_FILE="$(mktemp)"
FETCH_HTTP_CODE=$(curl -sS -o "${FETCH_RESP_FILE}" -w "%{http_code}" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${NS_HEADER[@]}" \
  -H "Content-Type: application/json" \
  --request POST \
  --data "${SBERCA_REQUEST_PAYLOAD}" \
  "${REQ_URL}" || true)

echo "[SBERCA-DIAG] fetch http_code: ${FETCH_HTTP_CODE}" >&2
if [[ "${FETCH_HTTP_CODE}" -lt 200 || "${FETCH_HTTP_CODE}" -gt 299 ]]; then
  echo "[SBERCA-DIAG] fetch error response: $(cat "${FETCH_RESP_FILE}" 2>/dev/null || true)" >&2
  rm -f "${FETCH_RESP_FILE}"
  exit 22
fi

cat "${FETCH_RESP_FILE}"
rm -f "${FETCH_RESP_FILE}"
