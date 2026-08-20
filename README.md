# Omarchy Cloud Plugin

![Preview](preview.png)

Mount Google Drive, Dropbox, OneDrive and other cloud storage as ordinary
folders on Omarchy, with connection status in the bar.

Files appear in Nautilus like any other folder — open, edit, save, delete.
Behind the scenes it is [rclone](https://rclone.org/) mounted through FUSE and
supervised by systemd.

```
Bar widget  ──▶  systemd user units  ──▶  rclone mount  ──▶  ~/Cloud/<service>
  (status)         (supervision)           (transport)        (what you browse)
```

## Install

```bash
omarchy plugin add https://github.com/JoshuaFurman/omarchy-cloud-plugin.git --enable
```

Omarchy clones the repository, validates `manifest.json`, and then enables the
plugin. Review the source before accepting Omarchy's install prompt: plugins
run unsandboxed with your user permissions.

`rclone` is an external dependency and is not installed just by adding the
plugin. If it is missing, choosing **Install rclone** in the panel explicitly
runs Omarchy's system package flow (`omarchy pkg add rclone`), which may ask
for your password. You can install it yourself first with the same command.

## Connecting a service

Click the cloud icon in the bar, then **Connect a service…**. A terminal opens
and asks which provider to use, what to call the folder, and any credentials or
provider-specific choices it needs.

For another rclone backend, choose **Something else (guided by rclone)** and
enter its backend name. rclone then asks the complete provider-specific set of
questions; for example, SFTP asks for its host and user instead of silently
creating an empty connection.

OAuth services sign in through your browser. iCloud uses your regular Apple
Account password and then asks for a 2FA code in the terminal. When sign-in
finishes, the folder is mounted, bookmarked in the Files sidebar, and set to
mount again at every login.

## What it does to your system

After `rclone` is available, all runtime state is user-level and stays under
your home directory. The plugin creates or updates only its namespaced files,
its generated user service, and the bookmark lines for services you connect.
It refuses to replace a service file that does not carry the plugin's ownership
marker. Existing rclone remotes not created by this plugin are ignored.

| Path | What |
|------|------|
| `~/Cloud/<name>/` | Where each service is mounted |
| rclone's active config (normally `~/.config/rclone/rclone.conf`) | Credentials for services you explicitly connect; the plugin honors the path reported by `rclone config file` |
| `~/.config/omarchy-cloud/settings.conf` | Mount flags, read by systemd at login |
| `~/.config/omarchy-cloud/remotes/<name>.conf` | Per-service mount flags and plugin ownership record |
| `~/.config/systemd/user/omarchy-cloud-mount@.service` | Generated systemd user unit |
| `~/.config/gtk-3.0/bookmarks` | One sidebar line per connected service |
| `~/.cache/omarchy-cloud/` | Quota responses and the size-capped file cache |

Connecting or disconnecting a service changes rclone's credential file only
after an explicit action and never deletes provider-side data. The plugin never
copies or backs up `rclone.conf`: disconnect asks rclone to remove only the
selected remote and verifies that it is gone, leaving every unrelated remote
untouched. It also refuses to disconnect a remote without its own ownership
record, and keeps that record if stopping the mount or deleting credentials
cannot be verified. Obsolete full-config backups created by Cloud 0.2.0 and
earlier are deleted the next time a plugin helper runs.

Installing the `rclone` package is the only system-level operation; it is
initiated separately through Omarchy's package manager as described above.

## Things worth knowing

**Deleting skips the desktop trash.** FUSE mounts have no trash directory, so
Nautilus deletes go straight to the provider. Google Drive and Dropbox keep
their own server-side trash, so files are usually recoverable there — but
Ctrl+Z will not bring them back.

**This is a mount, not a sync client.** Files live in the cloud; the local
cache is a convenience. Mounts stop when you log out. Recently opened files
stay readable offline while they are still in the cache (`full` cache mode),
but a file you have never opened is not on your disk.

**Google Docs open in the browser.** Docs, Sheets and Slides aren't real files
— Drive only stores them online, and their size is unknown until they're
converted. rclone's docs are blunt about the consequence: through a mount they
report 0 bytes, and *"you may not be able to download Google docs using rclone
mount."* There is no flag that fixes it.

So the default is to show each one as a small link file that opens the document
in Google Docs, Sheets or Slides, where it's editable. Two alternatives are
available per service under **Settings → Google Docs handling**:

| Choice | Result |
|--------|--------|
| Open in Google Docs (default) | Small `.link.html` files; double-click opens the browser |
| Convert to Office files | `.docx` / `.xlsx` / `.pptx` — often 0 bytes and unopenable |
| Hide them | Google-native files don't appear at all |

**The shared OAuth credentials are rate-limited.** rclone's built-in Google
client ID is shared by every rclone user, and throttles under load. For a
large Drive, create your own client ID and switch under **Settings → Google
credentials**. The plugin stops the mount, saves the new client, runs rclone's
dedicated reconnect flow, and starts the mount again only after sign-in works.
Use a client ID you created yourself rather than credentials shared by someone
else; a client ID can expose relationships between accounts that use it.

## Per-service settings

Click the gear beside any connected service. Nothing chosen during setup is
permanent:

- **Google Docs handling** (Drive only) — the three options above
- **Mount at login** — on or off
- **Extra rclone flags** — anything from that backend's rclone page
- **Disconnect this service** — unmount, delete the saved sign-in, drop the
  bookmark. Nothing in the cloud is touched.

If a mount fails, its row offers both **Mount now** and **Sign in again** so an
expired or revoked provider token can be repaired without using the terminal.

Changing mount flags restarts that one mount so the change takes effect.

## Plugin settings

Right-click the bar widget → Settings, or edit the entry in
`~/.config/omarchy/shell.json`.

| Setting | Default | Notes |
|---------|---------|-------|
| Mount folder | `~/Cloud` | Changing it requires remounting each service |
| File cache | `full` | `off` breaks saving in most editors — see below |
| Cache size limit | 8 GB | Least recently used files are evicted first |
| Status refresh | 15 s | Local only, cheap |
| Storage usage refresh | 20 min | One network call per mounted service |
| Show text in bar | off | Prints `mounted/total` next to the icon |

On the cache mode: with `off`, a file cannot be open for reading and writing
at the same time, which is exactly what applications do when they save. Use
`writes` at minimum; `full` additionally gives correct random access and
offline reads of cached files.

## Using it from the terminal

Plugin helpers stay inside the installed checkout rather than modifying your
`PATH`. Every layer works on its own, which is also how you debug it.

```bash
CLOUD_PLUGIN="$HOME/.config/omarchy/plugins/furmware.cloud"

"$CLOUD_PLUGIN/bin/omarchy-cloud-connect"                   # setup wizard
"$CLOUD_PLUGIN/bin/omarchy-cloud-configure" gdrive          # service settings
"$CLOUD_PLUGIN/bin/omarchy-cloud-reconnect" gdrive          # re-run sign-in

"$CLOUD_PLUGIN/bin/omarchy-cloud-mount" status --with-quota # panel JSON
"$CLOUD_PLUGIN/bin/omarchy-cloud-mount" enable gdrive       # now + at login
"$CLOUD_PLUGIN/bin/omarchy-cloud-mount" stop gdrive         # this session
"$CLOUD_PLUGIN/bin/omarchy-cloud-mount" run gdrive          # foreground mount
"$CLOUD_PLUGIN/bin/omarchy-cloud-mount" forget gdrive --yes # delete credentials

systemctl --user status omarchy-cloud-mount@gdrive
journalctl --user -u omarchy-cloud-mount@gdrive -f
```

`forget` deletes local credentials and the bookmark. It never touches
anything stored in the cloud.

## Remove

If you also want to delete saved provider credentials, disconnect each service
from its settings screen first. Then run cleanup **before** removing the plugin
checkout:

```bash
CLOUD_PLUGIN="$HOME/.config/omarchy/plugins/furmware.cloud"
"$CLOUD_PLUGIN/bin/omarchy-cloud-uninstall"
omarchy plugin remove furmware.cloud
```

Cleanup stops and disables plugin-managed mounts, removes the generated systemd
user unit, and removes only this plugin's Files bookmarks. It preserves rclone
remotes and credentials, the `rclone` package, cached files, settings, and all
provider-side data. To also delete plugin settings and its namespaced cache:

```bash
"$CLOUD_PLUGIN/bin/omarchy-cloud-uninstall" --purge
omarchy plugin remove furmware.cloud
```

Even `--purge` leaves rclone credentials and provider-side data intact. The
plugin does not remove the shared `rclone` package because other tools may use
it.

## Experimental support

**iCloud Drive.** Connect it via **Something else** in the wizard (backend name
`iclouddrive`). It requires your regular Apple Account password; app-specific
passwords are rejected. rclone classifies this backend as experimental, and its
trust token expires every 30 days. Until the plugin can schedule that renewal,
reauthenticate manually with `omarchy-cloud-reconnect` as shown above.

rclone does not expose iCloud's storage quota, so the panel's slow usage refresh
calls Apple's storage endpoint with the session cookie rclone already saved.
That cookie stays in memory and is never printed or passed on a command line.

**Offline sync.** Only cached files work offline. A true offline folder needs
`rclone bisync` and a conflict-resolution story.

## Developing

Symlink the checkout into the plugin directory so edits apply in place:

```bash
ln -sfn ~/Projects/omarchy-cloud-plugin ~/.config/omarchy/plugins/furmware.cloud
omarchy-shell shell rescanPlugins
omarchy plugin enable furmware.cloud
```

QML files reload on `rescanPlugins`. **`Model.js` does not** — it is a
`.pragma library`, which the QML engine caches for the life of the process, so
changes to it need `omarchy restart shell`. Symptom: an edit that plainly
should have applied has no effect.

```bash
omarchy plugin validate .                 # manifest against the Omarchy schema
journalctl --user -f | grep -i qml        # QML load errors
```

## Requirements

- Omarchy 4 with the Quattro shell plugin system
- `rclone` (external; installed only on explicit request)
- `fuse3`, `python3`, and `gum` (included with Omarchy)
- systemd user services, network access to the selected provider, and a browser
  for OAuth-based providers

## License

MIT
