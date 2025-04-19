#!/bin/bash
exit_code="$1"

# Source http_aliases to import update_http_token function
shopt -s expand_aliases
source ~/.http_aliases

# Error handling logic
case "$exit_code" in
  401|403)
    echo "[AUTH ERROR] ($exit_code) Detected authentication issue. Refreshing token..." >&2
    update_http_token 2>&1 | tee -a /home/walt/httpie/logs/token-refresh.log
    ;;
  400|404)
    echo "[CLIENT ERROR] ($exit_code) Client request problem. Check your input." >&2
    ;;
  5??)
    echo "[SERVER ERROR] ($exit_code) Server encountered an error." >&2
    ;;
  *)
    echo "[UNKNOWN ERROR] ($exit_code) An unexpected error occurred." >&2
    ;;
esac
