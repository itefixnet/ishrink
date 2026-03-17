# ishrink URL Shortener

A lightweight Docker-based URL shortener using Bash, Nginx, and JSON configuration files.

This solution is designed for operators who want very fast redirects, low runtime complexity, and fully transparent configuration without a database. **Note:** This setup is optimized for deployments with infrequent URL changes. For scenarios with frequent, high-volume updates (>100/min sustained), the full config regeneration on each change may become a bottleneck.

## Why This Setup Stands Out

- **Nginx-native redirect speed**: redirects are served directly by Nginx location rules, not app runtime logic.
- **No database, no migration burden**: every mapping is plain JSON in `/app/urls`, versionable and easy to audit.
- **Zero-downtime updates**: URL changes are applied without restart through inotify-based reloads and direct tool-triggered reloads.
- **Operationally deterministic tooling**: `add_url`, `delete_url`, and `list_urls` provide a controlled interface for lifecycle management.
- **Safety guards built in**: duplicate short codes are blocked/warned, expiry is validated, and malformed JSON is rejected.
- **Complex URL-safe handling**: long query-string URLs are supported and rendered safely in generated Nginx config.
- **Container-first UX**: tools are bundled in the image and available on PATH, so behavior is consistent across environments.

## Quick Start

```bash
# 1. Start the service
docker-compose up --build -d

# 2. Add shortened URLs (no restart needed)
docker-compose exec shortener add_url links.json https://github.com --short "gh"
docker-compose exec shortener add_url links.json https://example.com --prefix "ex"

# 3. Test locally
curl -I http://localhost:8080/gh
```

That's it. No restart is needed after adding URLs.

`add_url` is bundled inside the Docker image and available on `PATH`. It always writes files under `/app/urls` and prints a ready-to-use short URL based on `SHORT_BASE_URL` (set in `docker-compose.yml`, defaults to `https://go.example.com`).

## Adding URLs with add_url

The `add_url` command simplifies adding new shortened URLs. It automatically generates short codes, handles JSON formatting, and supports prefix/suffix customization.

The printed short URL base is controlled by `SHORT_BASE_URL` set in `docker-compose.yml`.

### Basic usage

```bash
docker-compose exec shortener add_url <file.json> <url> [OPTIONS]
```

### Examples

**Auto-generate short code with prefix:**
```bash
docker-compose exec shortener add_url links.json https://github.com --prefix "gh"
# Result: https://go.example.com/gh_<random6> -> https://github.com
```

**Use specific short code:**
```bash
docker-compose exec shortener add_url links.json https://example.com --short "ex"
# Result: https://go.example.com/ex -> https://example.com
```

**With prefix, suffix, and description:**
```bash
docker-compose exec shortener add_url links.json https://docs.example.com --prefix "docs" --suffix "site" --desc "Official documentation"
# Result: https://go.example.com/docs_a1b2c3_site -> https://docs.example.com
```

**Override the printed public domain:**

Edit `SHORT_BASE_URL` in `docker-compose.yml`, then recreate the container:
```yaml
environment:
  - SHORT_BASE_URL=https://go.yourdomain.tld
```

### Script options

| Option | Arguments | Description |
|--------|-----------|-------------|
| `--prefix PREFIX` | string | Add prefix to generated short code |
| `--suffix SUFFIX` | string | Add suffix to generated short code |
| `--short CODE` | string | Use specific short code (no auto-generation) |
| `--desc DESCRIPTION` | string | Add description/comment for the mapping |
| `--expiry DATETIME` | ISO 8601 string | Set expiry date (e.g. `2026-12-31T23:59:59`) |
| `--help` | none | Show usage information |
| `SHORT_BASE_URL` | env var (set in docker-compose.yml) | Base URL used when printing the ready-to-use short link |

## List and Delete Tools

### list_urls

List entries in one JSON file with expiry status.

  docker-compose exec shortener list_urls links.json

Output includes:
- short code
- status (`active`, `expired`, `invalid`)
- expiry value (if present)
- target URL

### delete_url

Delete entries by short code from one JSON file.

After deletion, config is regenerated and Nginx is reloaded automatically.

Exact match:

  docker-compose exec shortener delete_url links.json gh

Wildcard match (`*` and `?`):

  docker-compose exec shortener delete_url links.json 'gh_*' --wildcard

Dry run (preview only):

  docker-compose exec shortener delete_url links.json 'promo-*' --wildcard --dry-run

## Architecture & How It Works

This shortener uses Nginx's **map directive** for efficient, O(1) URI-to-target lookups:

1. **Configuration Generation** (`generate_redirects.sh`): Reads JSON files from `/app/urls`, validates expiry dates, and generates an Nginx map structure. Only non-expired entries are included.

2. **Map-based Routing**: The generated configuration contains:
   ```nginx
   map $request_uri $redirect_target {
       default "";
       "/gh" "https://github.com";
       "/ex" "https://example.com";
       ...
   }
   ```

3. **Single Location Block**: All requests go through one location that checks if a mapping exists:
   ```nginx
   location / {
       if ($redirect_target != "") {
           return 301 $redirect_target;
       }
       return 404;
   }
   ```

4. **Reload Triggers**: Configuration is regenerated and reloaded when:
   - JSON files in `/app/urls` change (monitored by inotifywait)
   - `add_url` or `delete_url` tools are called (immediate regenerate + reload)

## Auto Reload Behavior

- On container start, `entrypoint.sh` generates the initial map configuration.
- A background watcher (`inotifywait`) monitors `/app/urls` for create/modify/delete/move events and triggers regeneration.
- `add_url` and `delete_url` tools also trigger immediate generate + reload after modifying JSON files, ensuring changes are active within milliseconds.

## URL Entry Schema

Each URL mapping supports:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `short` | string | Yes | The short code (e.g., "gh" for `/gh`) |
| `url` | string | Yes | The target URL to redirect to |
| `description` | string | No | Human-readable description |
| `expiry` | ISO 8601 datetime | No | When this redirect expires (e.g., "2026-12-31T23:59:59") |

## Troubleshooting

**URLs not redirecting after adding JSON files?**
- Check container logs: `docker-compose logs -f shortener`
- Verify the file landed under `urls/` and contains valid JSON
- Check generated config: `docker-compose exec shortener cat /etc/nginx/conf.d/redirects.conf`

**"Connection refused" on localhost:8080?**
- Ensure container is running: `docker-compose ps`
- Check if port 8080 is already in use

**Nginx welcome page appears instead of redirects?**
- Rebuild to ensure stock `default.conf` is removed: `docker-compose up --build -d`
- Confirm active config: `docker-compose exec shortener ls -la /etc/nginx/conf.d/`
- Inspect generated routes: `docker-compose exec shortener cat /etc/nginx/conf.d/redirects.conf`

**Expired URLs still redirecting?**
- Verify ISO 8601 format: `"2026-12-31T23:59:59"`
- If you edited JSON manually, wait a moment for the watcher to regenerate config, then check logs
