#!/bin/bash

# delete_url.sh - Delete entries from a JSON file in /app/urls by short code.
# Usage: delete_url <file.json> <short|pattern> [--wildcard] [--dry-run]

set -e

URLS_DIR="/app/urls"

show_usage() {
    cat << EOF
Usage: delete_url <file.json> <short|pattern> [OPTIONS]

Arguments:
  file.json         JSON file name under /app/urls
  short|pattern     Short code to delete (exact by default)

Options:
  --wildcard        Treat second argument as a wildcard pattern (* and ?)
  --dry-run         Show what would be removed without writing changes
  --help            Show this help message

Examples:
  delete_url links.json gh
  delete_url links.json 'gh_*' --wildcard
  delete_url links.json 'promo-2026-*' --wildcard --dry-run
EOF
}

glob_to_regex() {
    local glob="$1"
    local regex="^"
    local i c

    for ((i=0; i<${#glob}; i++)); do
        c="${glob:$i:1}"
        case "$c" in
            '*') regex+=".*" ;;
            '?') regex+="." ;;
            '.'|'+'|'('|')'|'|'|'^'|'$'|'{'|'}'|'['|']'|'\\') regex+="\\$c" ;;
            *) regex+="$c" ;;
        esac
    done

    regex+="$"
    printf "%s" "$regex"
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
match_value="$2"
shift 2

wildcard_mode="false"
dry_run="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wildcard)
            wildcard_mode="true"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
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

if [[ "$file_name" == */* ]]; then
    echo "ERROR: Use file name only (example: links.json). Files are always read from ${URLS_DIR}."
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

temp_norm="${file_path}.norm.tmp"
temp_new="${file_path}.new.tmp"

jq 'if type == "array" then . else [.] end' "$file_path" > "$temp_norm"

if [[ "$wildcard_mode" == "true" ]]; then
    regex="$(glob_to_regex "$match_value")"
    removed_count=$(jq --arg re "$regex" '[.[] | select((.short // "") | test($re))] | length' "$temp_norm")

    if [[ "$removed_count" -eq 0 ]]; then
        echo "No matching entries found for wildcard pattern: $match_value"
        rm -f "$temp_norm"
        exit 0
    fi

    echo "Matched entries:"
    jq -r --arg re "$regex" '.[] | select((.short // "") | test($re)) | "  \(.short) -> \(.url)"' "$temp_norm"

    jq --arg re "$regex" '[.[] | select(((.short // "") | test($re)) | not)]' "$temp_norm" > "$temp_new"
else
    removed_count=$(jq --arg s "$match_value" '[.[] | select((.short // "") == $s)] | length' "$temp_norm")

    if [[ "$removed_count" -eq 0 ]]; then
        echo "No entry found for short code: $match_value"
        rm -f "$temp_norm"
        exit 0
    fi

    echo "Matched entries:"
    jq -r --arg s "$match_value" '.[] | select((.short // "") == $s) | "  \(.short) -> \(.url)"' "$temp_norm"

    jq --arg s "$match_value" '[.[] | select((.short // "") != $s)]' "$temp_norm" > "$temp_new"
fi

if [[ "$dry_run" == "true" ]]; then
    echo ""
    echo "Dry run: $removed_count entrie(s) would be removed."
    rm -f "$temp_norm" "$temp_new"
    exit 0
fi

mv "$temp_new" "$file_path"
rm -f "$temp_norm"

if [[ -x /app/generate_redirects.sh ]] && command -v nginx >/dev/null 2>&1; then
    /app/generate_redirects.sh
    nginx -s reload >/dev/null 2>&1 || true
fi

echo ""
echo "Deleted $removed_count entrie(s) from $file_path"
