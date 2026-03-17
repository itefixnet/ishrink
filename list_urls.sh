#!/bin/bash

# list_urls.sh - List entries from a JSON file in /app/urls with expiry status.
# Usage: list_urls <file.json>

set -e

URLS_DIR="/app/urls"

show_usage() {
    cat << EOF
Usage: list_urls <file.json>

Arguments:
  file.json   JSON file name under /app/urls

Description:
  Lists short URLs and target URLs with expiry information and status.

Examples:
  list_urls links.json
EOF
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    show_usage
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required"
    exit 1
fi

file_name="$1"

if [[ "$file_name" == "$URLS_DIR"/* ]]; then
    file_name="${file_name#${URLS_DIR}/}"
elif [[ "$file_name" == */* ]]; then
    echo "ERROR: Use file name only (example: links.json) or an absolute path under ${URLS_DIR}."
    exit 1
fi

file_path="${URLS_DIR}/${file_name}"

if [[ ! -f "$file_path" ]]; then
    echo "ERROR: File not found: $file_path"
    exit 1
fi

if ! jq empty "$file_path" >/dev/null 2>&1; then
    echo "ERROR: $file_path contains invalid JSON"
    exit 1
fi

printf "%-24s %-8s %-20s %s\n" "SHORT" "STATUS" "EXPIRY" "URL"
printf "%-24s %-8s %-20s %s\n" "------------------------" "--------" "--------------------" "---"

count=0
active=0
expired=0
invalid=0
no_expiry=0

while IFS=$'\t' read -r short url expiry; do
    [[ -z "$short" || -z "$url" ]] && continue

    status="active"
    expiry_out="-"

    if [[ -n "$expiry" ]]; then
        expiry_out="$expiry"
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || true)
        now_epoch=$(date +%s)

        if [[ -z "$expiry_epoch" ]]; then
            status="invalid"
            ((++invalid))
        elif (( now_epoch > expiry_epoch )); then
            status="expired"
            ((++expired))
        else
            status="active"
            ((++active))
        fi
    else
        status="active"
        ((++active))
        ((++no_expiry))
    fi

    printf "%-24s %-8s %-20s %s\n" "$short" "$status" "$expiry_out" "$url"
    ((++count))
done < <(
    jq -r '
        if type == "array" then .[] else . end |
        [.short // "", .url // "", .expiry // ""] | @tsv
    ' "$file_path"
)

echo ""
echo "Total entries: $count"
echo "Active: $active | Expired: $expired | Invalid expiry: $invalid | No expiry: $no_expiry"
