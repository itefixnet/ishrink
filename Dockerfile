FROM nginx:alpine

RUN apk add --no-cache jq bash inotify-tools

# Remove stock nginx site so only generated redirects config is active.
RUN rm -f /etc/nginx/conf.d/default.conf

WORKDIR /app

COPY generate_redirects.sh entrypoint.sh add_url.sh list_urls.sh delete_url.sh /app/
COPY nginx.conf /etc/nginx/nginx.conf

RUN chmod +x /app/generate_redirects.sh /app/entrypoint.sh /app/add_url.sh /app/list_urls.sh /app/delete_url.sh && \
    ln -sf /app/add_url.sh /usr/local/bin/add_url && \
    ln -sf /app/list_urls.sh /usr/local/bin/list_urls && \
    ln -sf /app/delete_url.sh /usr/local/bin/delete_url

EXPOSE 80

CMD ["/app/entrypoint.sh"]
