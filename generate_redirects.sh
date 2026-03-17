#!/bin/bash

# Generate Nginx redirect configuration from JSON URL mappings.
# Scans urls/ directory for JSON files and creates a map-based routing structure.

URLS_DIR="/app/urls"
NGINX_CONF_FILE="/etc/nginx/conf.d/redirects.conf"

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed"
    exit 1
fi

check_expiry() {
    local expiry_str="$1"
    
    if [[ -z "$expiry_str" ]]; then
        return 1  # No expiry, not expired
    fi
    
    # Parse ISO 8601 datetime and compare with current time
    local expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    
    if [[ -z "$expiry_epoch" ]]; then
        echo "WARNING: Invalid expiry date format: $expiry_str"
        return 1
    fi
    
    if (( now_epoch > expiry_epoch )); then
        return 0  # Expired
    else
        return 1  # Not expired
    fi
}

generate_redirects() {
    # Create urls directory if it doesn't exist
    mkdir -p "$URLS_DIR"
    
    local -a map_entries=()
    local -A seen_shorts=()
    local count=0
    
    # Process all JSON files in urls directory
    for json_file in "$URLS_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        
        # Check if file is valid JSON
        if ! jq empty "$json_file" 2>/dev/null; then
            echo "Error reading $json_file: Invalid JSON"
            continue
        fi
        
        # Process each entry (handle both single object and array).
        # Use process substitution to keep loop in current shell
        # so map_entries/count updates are preserved.
        while IFS=$'\t' read -r short url expiry; do
            
            # Skip empty lines
            [[ -z "$short" || -z "$url" ]] && continue
            
            # Check expiry
            if [[ -n "$expiry" ]] && check_expiry "$expiry"; then
                echo "Skipping expired URL: $short"
                continue
            fi

            # Prevent duplicate entries in map.
            if [[ -n "${seen_shorts[$short]}" ]]; then
                echo "WARNING: Duplicate short code '$short' in $json_file (already defined in ${seen_shorts[$short]}). Keeping first mapping."
                continue
            fi
            seen_shorts[$short]="$json_file"
            
            # Add map entry: escape quotes and backslashes for nginx map context
            local escaped_url="$url"
            escaped_url="${escaped_url//\\/\\\\}"
            escaped_url="${escaped_url//\"/\\\"}"
            map_entries+=("    \"/$short\" \"$escaped_url\";")
            echo "Added redirect: /$short -> $url"
            ((count++))
        done < <(
            jq -r '
                if type == "array" then .[] else . end |
                [.short // "", .url // "", .expiry // ""] | @tsv
            ' "$json_file"
        )
    done
    
    # Generate nginx configuration with map-based routing
    local nginx_config="map \$request_uri \$redirect_target {
    default \"\";
"
    
    # Add all map entries
    for entry in "${map_entries[@]}"; do
        nginx_config+="$entry"$'\n'
    done
    
    nginx_config+="
}

server {
    listen 80 default_server;
    server_name _;

    location / {
        if (\$redirect_target != \"\") {
            return 301 \$redirect_target;
        }
        return 404;
    }
}
"
    
    # Write nginx configuration
    mkdir -p "$(dirname "$NGINX_CONF_FILE")"
    echo "$nginx_config" > "$NGINX_CONF_FILE"
    
    echo "Nginx configuration written to $NGINX_CONF_FILE"
    echo "Total redirects configured: $count"
}

generate_redirects
