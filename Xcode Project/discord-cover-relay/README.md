# LopLop Player Discord cover relay

Discord fetches Rich Presence images from public HTTPS URLs. This small relay lets Discord fetch a local track's embedded cover without opening an inbound port on the Mac running LopLop Player.

## Run the relay

Run this service on a host with a public DNS name. Put Caddy, nginx, or another HTTPS reverse proxy in front of it. The example below assumes Caddy and the domain `covers.example.com`.

```sh
export DISCORD_COVER_TOKEN="$(openssl rand -hex 32)"
export PUBLIC_BASE_URL="https://covers.example.com"
python3 server.py
```

Example Caddy site:

```caddyfile
covers.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Keep the generated token private. In LopLop Player, open Settings and enter `https://covers.example.com` as the Cover relay HTTPS URL and paste the token into Cover relay upload token. Use the same value for `DISCORD_COVER_TOKEN` on the relay host.

## Data handling

The app downsizes artwork to a 256-pixel JPEG before uploading it. The relay accepts JPEG, PNG, or WebP up to 512 KiB, requires a bearer token for uploads, returns an unguessable public image URL, and keeps at most 128 images in memory for up to 10 minutes. Images are not written to disk; stopping the relay clears its cache. The HTTPS reverse proxy encrypts transport. Discord can fetch the image while its URL is active and may cache its own copy beyond the relay's lifetime.

The image URLs are bearer links: anyone who obtains one can view that cover until it expires. The relay avoids logging request paths so it does not write those links to its access log. Use a host you control and do not expose the relay over plain HTTP to the public internet.

## Protocol

- `POST /v1/covers`: authenticated raw image upload (`Content-Type: image/jpeg`); returns `{"url":"https://.../c/<random-token>"}`.
- `GET /c/<random-token>`: fetches the temporarily cached image for Discord.

The relay binds to `127.0.0.1:8787` by default. Set `PORT` or `BIND_HOST` to override those values.
