#!/bin/sh
# Patches GoTrue SMS hook env vars in Supabase docker-compose.yml
# Usage: sh patch-compose.sh /path/to/docker-compose.yml
FILE="${1:-/work/docker/docker-compose.yml}"
sed -i 's/.*GOTRUE_HOOK_SEND_SMS_ENABLED.*/      GOTRUE_HOOK_SEND_SMS_ENABLED: "true"/' "$FILE"
sed -i 's|.*GOTRUE_HOOK_SEND_SMS_URI.*|      GOTRUE_HOOK_SEND_SMS_URI: "https://api.dangg.app/functions/v1/send-sms-hook"|' "$FILE"
sed -i 's|.*GOTRUE_HOOK_SEND_SMS_SECRETS.*|      GOTRUE_HOOK_SEND_SMS_SECRETS: "v1,whsec_9pJLDatnvvANKP3sJGZ+1nD8nDa2gTaggOdl5m8t9wQ="|' "$FILE"
echo "Patch applied:"
grep GOTRUE_HOOK_SEND_SMS "$FILE"
