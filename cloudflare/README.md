# ☁️ Cloudflare Admin Panel (free)

This folder is a self-contained Cloudflare Worker that provides:

- **Admin panel** (HTML) to create/manage licenses, watch devices and force updates.
- **License API** used by the Android app (`POST /api/client/license`).
- **Release API** used by the Android app for update checks (`GET /api/client/release`).

It needs **zero paid services** — the Cloudflare Free plan (Workers + KV) is enough.

## 1. Deploy

```bash
cd cloudflare
npm install

# Create 3 KV namespaces (run once, copy the IDs)
npx wrangler kv namespace create LICENSES
npx wrangler kv namespace create DEVICES
npx wrangler kv namespace create CONFIG
```

Paste the three IDs into `wrangler.toml`, then:

```bash
# (recommended) admin key secret
npx wrangler secret put ADMIN_KEY

# deploy
npx wrangler deploy
```

You will get a URL like `https://dns-changer-admin.YOUR_SUBDOMAIN.workers.dev`.

## 2. First login

Open `https://...workers.dev/admin`. If you set `ADMIN_KEY` secret, use it to log in.
Otherwise you can set the admin key from the **Settings** tab (first boot allows setting it via the API).

## 3. Create a license

1. Licenses tab → fill **plan name**, **device limit**, **duration (days)** and the **private DNS servers** (IPs, comma separated, e.g. `1.1.1.1, 1.0.0.1`).
2. Click **Generate license key** → copy the key and send it to your user.

The app shows the subscription DNS only as a locked "active" option — the real
addresses are base64-encoded in the API response and never displayed in the UI.

## 4. Device management

Click **Devices** on any license to see every device bound to it (name, id,
first/last seen, IP) and remove devices to free up slots.

## 5. Force updates when you publish a new release

In **Settings**:

- **Minimum required version** — every app with a lower version is forced to update.
- **Killed versions** — comma separated tags; apps on those versions are disabled.

When an app is forced to update it shows a full-screen warning with a **direct
APK download** button (it never opens GitHub).

> Tip: add the GitHub Actions secrets `CLOUDFLARE_WORKER_URL` and `ADMIN_KEY` to
> the repository. Then every release workflow automatically sets the new version
> as the minimum version, so the previous version stops working right after you
> publish.

## API reference

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| POST | `/api/client/license` | none | `{action:"activate"|"check", license_key, device_id, device_name}` |
| GET | `/api/client/release?version=X` | none | latest release + killed versions + min version |
| GET/POST | `/api/admin/config` | `x-admin-key` | read/update settings |
| GET/POST | `/api/admin/licenses` | `x-admin-key` | list / create / update / delete / revoke licenses |
| GET | `/api/admin/license/:key` | `x-admin-key` | license + devices |
| DELETE | `/api/admin/license/:key/devices/:id` | `x-admin-key` | remove a device |
| GET | `/api/admin/stats` | `x-admin-key` | totals |
| POST | `/api/admin/refresh_release` | `x-admin-key` | refresh cached GitHub release |
