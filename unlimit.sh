#!/bin/bash
PORTAL="http://172.20.175.201:8090/httpclient.html"
CREDS="$HOME/wifi/creds.txt"

while IFS=: read -r user pass; do
    [ -z "$user" ] && continue
    echo "[unlimit] trying $user ..."

    response=$(curl -k -s --max-time 5 \
        -d "mode=191&username=${user}&password=${pass}&a=$(date +%s)000&producttype=0" \
        "$PORTAL")

    if echo "$response" | grep -qiE "success|logged in|already"; then
        echo "[unlimit] ✅ CONNECTED as: $user"
        exit 0
    else
        echo "[unlimit] ❌ failed: $user"
    fi
    sleep 1
done < "$CREDS"

echo "[unlimit] ❌ no credential worked"
exit 1
