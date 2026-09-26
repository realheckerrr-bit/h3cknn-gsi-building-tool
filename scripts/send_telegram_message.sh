#!/usr/bin/env bash
# Send a prepared HTML message without exposing the bot token in logs.

set -Eeuo pipefail

BOT_TOKEN="${1:-}"
CHAT_ID="${2:-}"
MESSAGE_FILE="${3:-}"

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$MESSAGE_FILE" ] || [ ! -f "$MESSAGE_FILE" ]; then
  echo "Usage: send_telegram_message.sh <bot-token> <chat-id> <html-message-file>" >&2
  exit 2
fi

RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/telegram-response.XXXXXX")
trap 'rm -f -- "$RESPONSE_FILE"' EXIT

# Retry transient network/HTTP failures. The response body is kept separate so
# Telegram's useful error can be shown without printing the URL containing the
# bot token.
HTTP_STATUS=$(curl --silent --show-error \
  --connect-timeout 15 --max-time 90 \
  --retry 3 --retry-delay 2 \
  --output "$RESPONSE_FILE" --write-out '%{http_code}' \
  --request POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "text@${MESSAGE_FILE}" || true)

if [ "$HTTP_STATUS" != "200" ]; then
  echo "Telegram notification failed (HTTP ${HTTP_STATUS:-unknown})." >&2
  if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "404" ]; then
    echo "The bot token is invalid, revoked, or the Bot API endpoint was not found; rotate it with BotFather and update the TELEGRAM_BOT_TOKEN repository secret." >&2
  elif [ "$HTTP_STATUS" = "400" ]; then
    echo "Telegram rejected the message; check TELEGRAM_CHAT_ID and HTML markup." >&2
  fi
  if [ -s "$RESPONSE_FILE" ]; then
    sed -E 's/"description":"[^"]*"/"description":"redacted"/' "$RESPONSE_FILE" >&2
  fi
  exit 1
fi

if ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$RESPONSE_FILE"; then
  echo "Telegram returned HTTP 200 without confirming delivery." >&2
  sed -E 's/"description":"[^"]*"/"description":"redacted"/' "$RESPONSE_FILE" >&2
  exit 1
fi

echo "Telegram notification delivered."
