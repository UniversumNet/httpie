#!/bin/bash

LOG_FILE="$HOME/httpie/logs/token_manager.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[RUN] $(date) - token generation started"

# Path to environment variables file
ENV_FILE="/home/walt/httpie/env/oauth2/client-credential/openproject"
ACCESS_TOKEN_FILE="/home/walt/httpie/session/oauth-tokens/openproject_access_token"
TOKEN_EXPIRATION_FILE="/home/walt/httpie/session/oauth-tokens/openproject_token_expiration"

# Check if the environment file exists
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: Environment file not found at $ENV_FILE"
  exit 1
fi

# Load environment variables
source "$ENV_FILE"

# Validate required environment variables
if [[ -z "$TOKEN_URL" || -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "Error: Missing required environment variables. Please check $ENV_FILE."
  exit 1
fi

# Check if token and expiration files exist
if [[ -f "$ACCESS_TOKEN_FILE" && -f "$TOKEN_EXPIRATION_FILE" ]]; then
  ACCESS_TOKEN=$(cat "$ACCESS_TOKEN_FILE")
  TOKEN_EXPIRATION=$(cat "$TOKEN_EXPIRATION_FILE")
else
  ACCESS_TOKEN=""
  TOKEN_EXPIRATION=0
fi

# Get the current time in Unix epoch
CURRENT_TIME=$(date +%s)
EXPIRY_BUFFER=300 # 5-minute buffer to refresh before expiration

# Check if token is missing, expired, or about to expire
if [[ -z "$ACCESS_TOKEN" || "$CURRENT_TIME" -ge "$((TOKEN_EXPIRATION - EXPIRY_BUFFER))" ]]; then
  echo "Access token missing or expired. Requesting a new token..."

  # Send request using Httpie with form data
  RESPONSE=$(http --ignore-stdin --check-status --form POST "$TOKEN_URL" \
    grant_type=client_credentials \
    client_id="$CLIENT_ID" \
    client_secret="$CLIENT_SECRET" \
    Content-Type:application/x-www-form-urlencoded 2>&1)

  # Check for request error
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to request token. Response: $RESPONSE"
    exit 1
  fi

  # Extract token and expiration using jq
  ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
  CREATED_AT=$(echo "$RESPONSE" | jq -r '.created_at')
  EXPIRES_IN=$(echo "$RESPONSE" | jq -r '.expires_in')

  # Validate token extraction
  if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    echo "Error: Failed to retrieve access token. Response: $RESPONSE"
    exit 1
  fi

  # Calculate the expiration time
  TOKEN_EXPIRATION=$((CREATED_AT + EXPIRES_IN))

  # Save the token and expiration time to files
  echo "$ACCESS_TOKEN" > "$ACCESS_TOKEN_FILE"
  echo "$TOKEN_EXPIRATION" > "$TOKEN_EXPIRATION_FILE"

  echo "Access token successfully retrieved and saved. Expires in $EXPIRES_IN seconds."
else
  echo "Valid access token found. Proceeding with the request."
fi
