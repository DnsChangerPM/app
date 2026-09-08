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

Open `https://...workers.dev/admin`.

- If you set the `ADMIN_KEY` secret, paste it on the login screen (or open `/admin?key=YOUR_ADMIN_KEY`).
- If **no** key exists yet (no secret and nothing in KV), the panel shows a **"First boot — set admin key"**
  form. Choose a key (min 8 chars) — it is saved to KV and you are logged in immediately.
  From then on that key is required; the setup form never appears again.

### Getting `Unauthorized` on login?

| Cause | Fix |
| --- | --- |
| Key typed differently from the secret (typo, extra characters) | `npx wrangler secret put ADMIN_KEY` again with the key you want, then log in with exactly that value. |
| Secret was set on a **different** Worker than the one you opened (e.g. `black-snow-...` vs `dns-changer-admin`) | Check `name` in `wrangler.toml`; run `npx wrangler secret list` in the same folder to see which Worker has the secret. |
| Worker deployed before you added the secret and you're not sure what it is | Set a new one: `npx wrangler secret put ADMIN_KEY` (secrets take effect immediately, no redeploy needed). |
| A key was set in KV on first boot and you forgot it | Either set the `ADMIN_KEY` secret (it works in addition to the KV key), or delete the `config` key from the `CONFIG_KV` namespace in the Cloudflare dashboard to return to first-boot mode. |
| Browser has an old wrong key cached | Click **Logout** (clears `localStorage`) and log in again. |

To change the key later, use **Settings → Admin key** in the panel, or rotate the `ADMIN_KEY` secret.

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
| GET | `/api/public/health` | none | `{ok:true, api:2, ...}` — CI and the app use it to detect a missing or outdated Worker |
| POST | `/api/client/license` | none | `{action:"activate"|"check", license_key, device_id, device_name}` |
| GET | `/api/client/release?version=X` | none | latest release + killed versions + min version |
| GET | `/api/admin/status` | none | `{configured: bool}` — whether an admin key exists yet |
| GET/POST | `/api/admin/config` | `x-admin-key` | read/update settings (POST `{admin_key}` is allowed **without** auth only while no key exists — first boot) |
| GET/POST | `/api/admin/licenses` | `x-admin-key` | list / create / update / delete / revoke licenses |
| GET | `/api/admin/license/:key` | `x-admin-key` | license + devices |
| DELETE | `/api/admin/license/:key/devices/:id` | `x-admin-key` | remove a device |
| GET | `/api/admin/stats` | `x-admin-key` | totals |
| POST | `/api/admin/refresh_release` | `x-admin-key` | refresh cached GitHub release |

### Error semantics (important for the Android app)

- **Unknown license key** → HTTP **200** with `{ok:false, status:"not_found", ...}`.
  HTTP 404 is reserved for *missing routes*, so a wrong key is never confused
  with a missing/outdated server.
- License keys are stored canonically (no dashes) and **both formats work**:
  users may enter `ABCDEFGHIJKLMNOP` or `ABCD-EFGH-IJKL-MNOP`. Previous Worker
  versions stored keys with dashes but looked them up without, so even a
  correct key was reported as not found (and the old app showed
  "Server error (404)"). This Worker migrates such legacy records
  automatically on first access — just redeploy it.
- `expired`, `revoked`, `banned`, `limit_reached` are also HTTP 200 with
  `ok:false` and a human-readable `message`.
- HTTP 4xx/5xx means a wrong URL, an outdated Worker or Cloudflare edge
  errors — the app reports these as server problems and offers a health check.
- After deploying, verify: `curl https://YOUR.workers.dev/api/public/health`
  must return `"api":2`. The release workflow refuses to build an APK against
  anything older.
