#!/bin/bash

# Container entrypoint: generates initial Nginx config, starts file watcher,
# then runs Nginx in the foreground.

# Generate initial redirect config
echo "Generating initial Nginx configuration..."
rm -f /etc/nginx/conf.d/default.conf
/app/generate_redirects.sh

# Watch urls/ directory and reload Nginx on any change
(
    while true; do
        inotifywait -r -e modify,create,delete,move /app/urls/ 2>/dev/null
        echo "URL files changed, regenerating Nginx config..."
        /app/generate_redirects.sh
        nginx -s reload
        echo "Nginx reloaded."
    done
) &

echo "Started URL file watcher (PID $!)."

# Run Nginx in foreground (keeps container alive)
exec nginx -g 'daemon off;'
