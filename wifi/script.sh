#!/bin/bash
PORTAL="http://172.20.175.201:8090/httpclient.html"

while true; do
    while IFS=: read -r user pass; do
        [ -z "$user" ] && continue
        echo "Trying $user ..."
        response=$(curl -k -s -d "mode=191&username=${user}&password=${pass}&a=$(date +%s)000&producttype=0" "$PORTAL")
        echo "  -> $response"

        if echo "$response" | grep -qi "success"; then
            echo "✅ Logged in as $user"
            exit 0
        fi
        sleep 1
    done < creds.txt
    echo "Cycle done, retrying in 30s..."
    sleep 30
done
