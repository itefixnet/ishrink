#!/bin/bash

# add_url.sh - Add a shortened URL mapping to a JSON file under /app/urls.
# Usage: add_url <file.json> <url> [--prefix PREFIX] [--suffix SUFFIX] [--short SHORT_CODE] [--desc DESCRIPTION] [--expiry ISO8601]

set -e

URLS_DIR="/app/urls"
base_short_url="${SHORT_BASE_URL:-https://go.example.com}"
base_short_url="${base_short_url%/}"

show_usage() {
    cat << EOF
Usage: add_url <file.json> <url> [OPTIONS]

Arguments:
  file.json   JSON file name under /app/urls (created if it does not exist)
  url         Target URL to redirect to

Options:
  --prefix PREFIX        Add prefix to generated short code
  --suffix SUFFIX        Add suffix to generated short code
  --short SHORT_CODE     Use specific short code (overrides auto-generation)
  --desc DESCRIPTION     Add description/comment for this mapping
  --expiry DATETIME      Expiry date in ISO 8601 format (e.g. 2026-12-31T23:59:59)
  --help                 Show this help message

Environment:
  SHORT_BASE_URL         Optional base URL for printed short links

Examples:
  # Auto-generate short code with prefix
    add_url links.json https://github.com --prefix "gh"

  # Specific short code
  add_url links.json https://example.com --short "ex"

  # With prefix, suffix, and description
  add_url links.json https://docs.example.com --prefix "docs" --suffix "site" --desc "Documentation site"

  # With expiry
  add_url links.json https://example.com/event --short "evt" --expiry "2026-12-31T23:59:59"

    # Complex URL (quote it)
    add_url links.json 'https://checkout.example.net/portal/manual-payment?exp=1774166771&invoice_id=488&payment_method=stripe&sig=ABC123'

Printed short URLs default to:
  ${base_short_url}/<short>

Override the printed base URL:
  SHORT_BASE_URL=https://go.example.com add_url links.json https://example.com --short "ex"

EOF
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

if [[ $# -lt 2 ]]; then
    show_usage
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required"
    exit 1
fi

file_name="$1"
url="$2"
shift 2

if [[ "$file_name" == */* ]]; then
    echo "ERROR: Use file name only (example: links.json). Files are always stored under ${URLS_DIR}."
    exit 1
fi

file_path="${URLS_DIR}/${file_name}"

short_exists() {
    local candidate="$1"
    local json_file

    for json_file in "$URLS_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        jq -e --arg s "$candidate" '
            if type == "array" then
                any(.[]?; (.short // "") == $s)
            else
                (.short // "") == $s
            end
        ' "$json_file" >/dev/null 2>&1 && return 0
    done

    return 1
}

prefix=""
suffix=""
short_code=""
description=""
expiry=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            prefix="$2"
            shift 2
            ;;
        --suffix)
            suffix="$2"
            shift 2
            ;;
        --short)
            short_code="$2"
            shift 2
            ;;
        --desc)
            description="$2"
            shift 2
            ;;
        --expiry)
            expiry="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [[ ! "$url" =~ ^https?:// ]]; then
    echo "ERROR: URL must start with http:// or https://"
    exit 1
fi

if [[ -n "$expiry" ]] && ! date -d "$expiry" +%s >/dev/null 2>&1; then
    echo "ERROR: --expiry must be a valid ISO 8601 date/time"
    exit 1
fi

if [[ -z "$short_code" ]]; then
    attempts=0
    while true; do
        generated_code=$(tr -dc 'a-z' </dev/urandom | head -c 6)
        candidate_code="$generated_code"

        if [[ -n "$prefix" ]]; then
            candidate_code="${prefix}_${candidate_code}"
        fi
        if [[ -n "$suffix" ]]; then
            candidate_code="${candidate_code}_${suffix}"
        fi

        if ! short_exists "$candidate_code"; then
            short_code="$candidate_code"
            break
        fi

        ((attempts++))
        if (( attempts >= 100 )); then
            echo "ERROR: Could not generate a unique short code after 100 attempts. Use --short to provide one."
            exit 1
        fi
    done
else
    if [[ -n "$prefix" ]]; then
        short_code="${prefix}_${short_code}"
    fi
    if [[ -n "$suffix" ]]; then
        short_code="${short_code}_${suffix}"
    fi

    if short_exists "$short_code"; then
        echo "ERROR: Short code '$short_code' already exists"
        exit 1
    fi
fi

if [[ ! "$short_code" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: short code can only contain letters, numbers, _ and -"
        exit 1
fi

mkdir -p "$URLS_DIR"

temp_file="${file_path}.tmp"

if [[ -f "$file_path" ]] && ! jq empty "$file_path" >/dev/null 2>&1; then
        echo "ERROR: $file_path contains invalid JSON"
        exit 1
fi

if [[ -f "$file_path" ]]; then
        jq \
            --arg short "$short_code" \
            --arg url "$url" \
            --arg description "$description" \
            --arg expiry "$expiry" \
            '
            def new_entry:
                {short: $short, url: $url}
                + (if $description != "" then {description: $description} else {} end)
                + (if $expiry != "" then {expiry: $expiry} else {} end);
            if type == "array" then
                . + [new_entry]
            else
                [., new_entry]
            end
            ' "$file_path" > "$temp_file"
else
        jq -n \
            --arg short "$short_code" \
            --arg url "$url" \
            --arg description "$description" \
            --arg expiry "$expiry" \
            '
            [
                {short: $short, url: $url}
                + (if $description != "" then {description: $description} else {} end)
                + (if $expiry != "" then {expiry: $expiry} else {} end)
            ]
            ' > "$temp_file"
fi

mv "$temp_file" "$file_path"

if [[ -x /app/generate_redirects.sh ]] && command -v nginx >/dev/null 2>&1; then
    /app/generate_redirects.sh
    nginx -s reload >/dev/null 2>&1 || true
fi

echo "Added: /$short_code -> $url"
echo "Short URL: ${base_short_url}/$short_code"
echo "File: $file_path"

echo ""
echo "Current mappings:"
jq -r '.[] | "  \(.short) -> \(.url)"' "$file_path" 2>/dev/null || true