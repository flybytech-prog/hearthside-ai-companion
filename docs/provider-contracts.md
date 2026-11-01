# Provider contracts

The implementation follows the macOS AI Usage menubar app, using Linux/XDG
equivalents for local storage. These endpoints are not public provider APIs,
so sanitized fixture tests protect the known response shapes.

## Discovery and failure behavior

The helper merges the process and login-shell `PATH`, then checks provider CLI
names and local data locations. The login-shell capture runs `$SHELL -ilc`
with a command built only from `echo` and `printenv`, so it works the same in
POSIX shells and fish. It reads only the allow-listed variables
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `PATH`, parses only the text between its begin and end
markers, and ignores startup-file noise. `--detect` runs only this discovery
step: it reads no credentials and makes no network requests.

Only tracked and installed providers are contacted. A sign-in file that cannot
be read or is not valid UTF-8 skips that source, and the next source is tried.
If a provider cannot be set up at all, only that provider reports a `storage`
failure; the others are still refreshed. Authentication and storage failures clear the widget's previous
reading; transient, rate-limit, and invalid-response failures preserve the
last successful reading in Plasma memory and mark it stale.

A failed token refresh is classified by what the token endpoint said, not as a
sign-out by default: a network error or a `5xx` reply is `transient`, a `429`
is `rate_limited` with a cooldown from `Retry-After`, and only a `4xx` grant
error (or an explicit logout flag) reports the provider as signed out. This
applies to Cursor, Antigravity, and Grok.

`Retry-After` accepts seconds or an HTTP date and defaults to five minutes
when missing or unparseable. The resulting cooldown is clamped to between now
and 24 hours from now.
Cooldowns are held in Plasma memory and are not written to disk.

## Claude Code

- Auth: `$CLAUDE_CONFIG_DIR/.credentials.json`, otherwise
  `~/.claude/.credentials.json`
- Usage: `GET https://api.anthropic.com/api/oauth/usage`
- Refresh: `POST https://platform.claude.com/v1/oauth/token`
- Metrics: Session, Weekly, Sonnet, Fable, Extra Usage

The `user:profile` scope is required when scope metadata exists.
`CLAUDE_CODE_OAUTH_TOKEN` setup tokens are intentionally ignored.

## Codex

- Auth: `$CODEX_HOME/auth.json` exclusively when set; otherwise
  `~/.config/codex/auth.json`, `~/.codex/auth.json`, then Secret Service
  `Codex Auth`
- Usage: `GET https://chatgpt.com/backend-api/wham/usage`
- Refresh: `POST https://auth.openai.com/oauth/token`
- Metrics: Session, Weekly, Spark, Spark Weekly, Credits

API-key-only documents are detected but cannot read ChatGPT subscription
usage.

## Cursor

- Auth: `~/.config/Cursor/User/globalStorage/state.vscdb` (plus the legacy
  `~/.cursor` equivalent), then Secret Service services
  `cursor-access-token` and `cursor-refresh-token`
- Usage:
  `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
- Plan:
  `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo`
- Refresh: `POST https://api2.cursor.sh/oauth/token`
- Metrics: Total Usage, Auto Usage, API Usage

Cursor refreshes early, within five minutes of the access token's expiry. If
that early refresh hits an outage or a `429` while the access token is still
valid, the helper uses the current token; the failure is reported only once
the token has actually expired. A refused grant still reports signed out. Each
helper run sends a given refresh token at most once.

## Antigravity

- Auth: Secret Service service `gemini`, username `antigravity`
- OAuth refresh metadata: resolved at runtime from the installed Antigravity IDE
  bundle; no OAuth client credentials are shipped in this repository
- Refresh: `POST https://oauth2.googleapis.com/token`
- Usage: `retrieveUserQuotaSummary`, falling back to
  `fetchAvailableModels`, on Google's daily Cloud Code and Cloud Code hosts
- Plan: `loadCodeAssist`
- Metrics: Gemini Session/Weekly and Claude Session/Weekly

The fallback also runs when the summary succeeds but holds no known quota
bucket. Each request tries both hosts. A `429` from one host is reported as
`rate_limited` (with its `Retry-After`) only if no host succeeds, and then no
further plan or quota requests are sent. If neither host answers, the provider
reports `transient`. A refresh outage leaves the derived-token cache untouched,
and each helper run sends a given refresh token at most once.

The derived access-token cache is documented in [Privacy](privacy.md).

## GitHub Copilot

- Auth: `~/.config/github-copilot/apps.json`, then `hosts.json`, then
  `~/.config/gh/hosts.yml`, then Secret Service `gh:github.com`
- Usage: `GET https://api.github.com/copilot_internal/user`
- Metrics: Credits, Chat, Completions

Unlimited and zero-entitlement buckets are not rendered.

## Devin

- Auth: `~/.local/share/devin/credentials.toml`, then the Linux Devin
  `state.vscdb`
- Usage:
  `POST /exa.seat_management_pb.SeatManagementService/GetUserStatus` on the
  configured HTTPS server or `https://server.codeium.com`
- Metrics: Daily, Weekly

## Grok

- Auth: `~/.grok/auth.json`
- Refresh: `POST https://auth.x.ai/oauth2/token`
- Usage: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
- Plan: `GET https://cli-chat-proxy.grok.com/v1/settings`
- Metric: Weekly

A missing or empty `auth.json`, or one with no usable account entry, reports
signed out. A file that exists but cannot be read, is not valid UTF-8, or is
not valid JSON reports `storage`. A usage `429` reports `rate_limited` with
its `Retry-After` and skips the plan request.

All credential rotations use source-aware, mode-`0600` writes and avoid
overwriting a concurrent login. A credential file that is a symlink is written
through to its final target, leaving the link in place; the write is refused
(`storage`) if the target is missing, is not a regular file, or is not owned
by the current user.

Claude Code, Codex, and Grok rotate refresh tokens, so each refresh holds a
per-provider cross-process lock (`flock` on an empty lock file, waiting up to
30 seconds). Under the lock the helper re-reads the exact credential source.
If another process already rotated the tokens, the helper uses them and sends
no refresh. Otherwise it sends at most one refresh `POST` per refresh token
and writes the result back with compare-before-write. If that write fails, the
provider reports a `storage` failure and does not reload or retry, because the
old refresh token has already been spent. If the lock stays busy, the provider
reports a `transient` failure without sending a refresh. Grok refreshes early,
within five minutes of expiry; if that early refresh fails for any reason
other than storage (including a busy lock) while its access token has not yet
expired, Grok still uses the current access token, and reports the failure
only once the token has expired. A refresh token that already failed in this
run is not resent; the earlier failure is reported again. If the re-read finds the
login gone (file deleted or emptied, or Codex switched to an API key), the
provider reports it as signed out; if the source cannot be read or decoded, or
the Secret Service lookup fails, it reports `storage`. Neither case sends a
refresh. The usage request
itself never runs under the lock. Provider CLIs do not take this lock;
compare-before-write still catches their concurrent writes.

## Chat tab

The Chat tab is not a provider contract: it shows each provider's own website
and never calls an API or reads the pages. It runs the helper only for Stay
signed in (see [below](#stay-signed-in-helper)), never with chat data. Sites,
their home pages and host lists live only in `plasmoid/contents/ui/ChatSites.js`.
The navigation rules below are the same with Stay signed in Off or Encrypted.

| Site | Home page | Site hosts | Sign-in hosts |
| --- | --- | --- | --- |
| Claude | `https://claude.ai/new` | claude.ai, claude.com, anthropic.com | accounts.google.com, appleid.apple.com |
| ChatGPT | `https://chatgpt.com/` | chatgpt.com, openai.com | accounts.google.com, login.microsoftonline.com, login.live.com, appleid.apple.com |
| Grok | `https://grok.com/` | grok.com, x.ai, x.com | accounts.google.com, appleid.apple.com |
| Gemini (best effort) | `https://gemini.google.com/app` | gemini.google.com, accounts.google.com, consent.google.com | accounts.google.com |
| GitHub Copilot | `https://github.com/login?return_to=%2Fcopilot` | github.com | github.com, accounts.google.com, appleid.apple.com |
| Microsoft Copilot | `https://copilot.microsoft.com/` | copilot.microsoft.com, microsoft.com, bing.com | login.microsoftonline.com, login.live.com, account.live.com, accounts.google.com, appleid.apple.com |
| Local (Ollama / Open WebUI), off by default | `http://localhost:3000/` | localhost, 127.0.0.1, [::1] | none |

GitHub Copilot starts at the sign-in page because signed-out visitors to
`/copilot` are redirected to a landing page; after sign-in GitHub returns to
`/copilot`.

A host matches when it equals a listed host or ends with `.` plus that host,
case-insensitively, so `evilclaude.ai` never matches `claude.ai`.

Custom addresses (`chatCustomUrls`, JSON `{siteId: url}`, written only by the
settings page):

- Only known site ids with a valid, non-empty address are kept, in catalog
  order; unreadable JSON, unknown ids, or invalid entries fall back to the
  built-in address. Every use re-validates the address.
- An address must be at most 2048 characters, contain no whitespace or user
  info (`@` in the host part), and use `https:`. Local may also use `http:`,
  but only with the host `localhost`, `127.0.0.1`, or `[::1]`. No other site
  may point at this computer. Control characters (U+0000–U+001F, U+007F) are
  rejected like whitespace.
- A custom address adds exactly its own host to the site (no subdomains); the
  built-in site and sign-in hosts still apply.

Navigation in a site view (main frame unless noted):

- Only `https:` main-frame pages load, plus `about:blank`. `http:`, `file:`,
  `data:`, `javascript:`, `view-source:`, `chrome:`, `qrc:`, other schemes, and
  malformed URLs (including user info in the host) are blocked.
- Exception for Local only: `http:` loads when the host is a loopback name
  (`localhost`, `127.0.0.1`, `[::1]`) and host plus port (80 when absent)
  equal those of Local's address exactly. Any other port, loopback spelling or
  host is blocked; with an `https:` custom address Local allows no `http:`.
- Every site except Local is blocked from this computer under any scheme:
  `localhost`, `*.localhost`, `[::1]`, `0.0.0.0`, and any `127.x.x.x` address in any
  numeric spelling.
- Embedded frames (subframes) may load `https:` from any host and `about:`,
  `blob:`, `data:` or srcdoc content, with two exceptions: an `http:` or
  `https:` frame on this computer (same test as above) is blocked for every
  site except Local, and Local's `http:` frames load only for the exact origin
  of its address. Malformed `http:`/`https:` frame URLs are blocked.
- Scope: these rules cover what the widget can intercept, which is main-frame
  and frame navigations and new windows. Background requests made by a page
  (fetch, XHR, WebSocket, images, scripts, styles) are not filtered, so a page
  can still reach this computer that way, directly or through names that
  resolve to it (such as `*.nip.io`), as in any browser. The same applies to
  the Local page's own subresources over `http:`.
- A clicked link to a host outside the site and sign-in hosts is cancelled and
  opened in the system browser.
- Other `https:` navigations, such as sign-in redirects and form posts, stay
  in the view.

New windows requested by a page:

- A popup dialog (`about:blank` or `https:`) or an `https:` window on one of
  the site's sign-in hosts opens in a sign-in overlay inside the popup, using
  the same profile as the site view, and closes when the page closes it.
- Any other `https:` window, or a sign-in window opened from the overlay,
  opens in the system browser only when you clicked to open it; windows a
  page opens by itself are dropped.
- Everything else is blocked, including every `http:` window (Local too) and
  windows to this computer from any site except Local.

**Open in browser** is offered only for a page of the current site: an
`https:` page (not on this computer, except for Local), or Local's own `http:`
loopback address.

Gemini sign-in may be refused by Google inside embedded browsers. The
Microsoft Copilot host lists are a best guess; a wrong entry only changes
whether a link opens inside the widget or in the browser.

## Stay signed in helper

For **Stay signed in → Encrypted** the plasmoid runs the helper for a few
fixed jobs. These commands touch no credentials, make no network requests,
and pass no chat data. The plasmoid builds them in
`plasmoid/contents/ui/ChatStorage.js` from fixed words and integers only, as
`env HEARTHSIDE_RUN=<n> HEARTHSIDE_APPLET=<applet> python3 -m hearthside ...`.
`HEARTHSIDE_RUN` is a run counter and `HEARTHSIDE_APPLET` the widget id; together
they keep command names unique across widgets and settings pages so replies are
told apart. The helper ignores both.

### Layout

- Encrypted folder (gocryptfs cipher directory):
  `$XDG_DATA_HOME/hearthside/vault/` (`~/.local/share` when `XDG_DATA_HOME` is
  unset or not absolute).
- Mount: `$XDG_RUNTIME_DIR/hearthside/vault/`. `XDG_RUNTIME_DIR` must be set,
  absolute, a real directory, owned by you and mode `0700`, else the reply is
  `no-runtime-dir`. The bare mountpoint is mode `0700` while mounting and
  `0500` while locked.
- Profiles: `<mount>/web/applet-<N>-g<G>/`, one per widget id `N` and profile
  generation `G` (`chatProfileGeneration`, raised by Clear chat data). Folders
  are mode `0700`.
- Lock file: `$XDG_RUNTIME_DIR/hearthside/vault.lock` (`flock`). Jobs that
  open a passphrase window (`create`, `unlock`, `change-passphrase`) wait for
  it as long as needed; all others give up after 5 seconds with `busy`.

A mount is used only after `/proc/self/mountinfo` shows a `fuse.gocryptfs`
mount of exactly that cipher directory with your `user_id` and without
`allow_other` or `allow_root`, and the mount root is a directory you own on a
different device than its parent. Every folder below it is opened one level
at a time without following symlinks.

### Commands

| Command | Does | Success reply |
| --- | --- | --- |
| `--vault status` | Reports the folder's state; cleans up a dead mount; never prompts | `{"ok":true,"state":"absent"}`, `"locked"`, `"unlocked"`, `"damaged"`, or `{"ok":true,"state":"unavailable","missing":[...]}` |
| `--vault create` | Creates and initialises the folder (kdialog `--newpassword`), then mounts it (kdialog `--password`) | `{"ok":true}` |
| `--vault unlock` | Mounts the folder (kdialog `--password`); already unlocked is success | `{"ok":true}` |
| `--vault lock` | `fusermount3 -u`; retried after 0.5 s and 1 s, never forced or lazy; already locked or a dead mount is success | `{"ok":true}` |
| `--vault change-passphrase` | `gocryptfs -passwd`, only while locked (kdialog `--password`, then `--newpassword`) | `{"ok":true}` |
| `--vault destroy` | Deletes the cipher directory and the bare mountpoint, only while not unlocked; nothing there is success | `{"ok":true}` |
| `--web-data prepare --store encrypted --applet N --generation G` | Creates `web/applet-N-gG/` inside the verified mount | `{"ok":true}` |
| `--web-data remove --store encrypted --applet N [--keep G]` | Deletes this widget's `applet-N-g*` folders, except generation `G` when given; nothing there is success | `{"ok":true}` |
| `--web-data purge` | Deletes the encrypted folder for `scripts/install.sh --uninstall-web-data`; refuses while anything is mounted at the mountpoint or from the cipher directory (also checks `/run/user/<uid>`); runs no tool | `{"ok":true,"removed":[]}` or `{"ok":true,"removed":["vault"]}` |

`absent` means there is no cipher directory or it is empty. `damaged` means the
cipher directory holds files but no regular `gocryptfs.conf`: gocryptfs can
neither open nor initialise it, so `create`, `unlock`, and `change-passphrase`
fail with `damaged` and only `destroy` (or `purge`) clears it.

`missing` lists, in this order, whichever of `gocryptfs`, `gocryptfs-v2`
(gocryptfs is older than 2.0, or its version can't be read), `kdialog`, and `fusermount3` are not found on
`PATH`. `--store` accepts only `encrypted`; there is no unencrypted store.

Argument rules (argparse exits 2 with a usage message on stderr otherwise):

- `--web-data` and `--vault` cannot be combined with each other or with
  `--json`, `--providers`, `--catalog`, or `--detect`.
- `--store`, `--applet`, `--generation`, and `--keep` need `--web-data`
  `prepare` or `remove`; `prepare` needs `--store`, `--applet`, and
  `--generation` and refuses `--keep`; `remove` needs `--store` and
  `--applet` and refuses `--generation`; `purge` takes none of them.
- `N` and `G` are plain decimal integers from 0 to 2147483648 (at most 10
  digits; no sign, spaces, or underscores).

### Replies and errors

Every job prints one JSON object on stdout and exits 0. Replies never contain
paths, names, counts, or passphrases; stderr carries only argparse usage.
Children get an argument list (no shell) with stdin, stdout, and stderr on
`/dev/null`; the only exceptions are the pipe between the second
change-passphrase dialog and gocryptfs, which the helper never reads, and the
version line of `gocryptfs -version`. gocryptfs runs with `-q -nosyslog`
(and `-init -q`, so the master key is never printed). Every child's arguments
are checked against an allow-list before it starts: gocryptfs gets only
`-init`, `-passwd`, `-q`, `-nosyslog`, and `-extpass` (each only in its phase,
plus a lone `-version`) and absolute paths; `fusermount3` only `-u
<mountpoint>`; kdialog only the new-passphrase dialog. Anything else (for
example `-passfile`, `-masterkey`, `-ko`, `-o`, `-config`, `-fsname`,
`-zerokey`, `-fusedebug`) and any argument containing `allow_` outside an
`-extpass` value is refused with `os-error`. `gocryptfs -passwd`, and with it
the Python extpass relay, runs with every `PYTHON*` variable removed and
`PYTHONNOUSERSITE=1` and `PYTHONSAFEPATH=1` set. A tool that `PATH` finds only
through a relative entry counts as missing.

Before mounting, under the lock and with nothing mounted, the bare mountpoint
must be empty. The only leftovers removed there are `web/applet-<N>-g<G>/`
folders you own (a chat that kept writing into the in-memory directory after
another widget locked the folder); they are deleted without following links.
Anything else there gives `mount-failed` and nothing is deleted.

A failure is `{"ok":false,"error":"<code>"}`:

| Code | Meaning |
| --- | --- |
| `missing-tool` | A needed tool is missing or could not start |
| `no-runtime-dir` | `XDG_RUNTIME_DIR` is unusable (see above) |
| `exists` | `create`: a folder already exists |
| `absent` | `unlock`, `change-passphrase`: no folder yet (or gocryptfs found no folder) |
| `damaged` | `create`, `unlock`, `change-passphrase`: the cipher directory holds files but no `gocryptfs.conf`; delete it with `destroy` |
| `cancelled` | The passphrase window was cancelled, or the passphrase was empty |
| `wrong-passphrase` | gocryptfs rejected the passphrase |
| `init-failed` | `create`: gocryptfs could not initialise the folder |
| `mount-failed` | `create`, `unlock`: the mount did not come up, or the mountpoint holds something other than leftover profile folders |
| `not-verified` | The folder is not unlocked, or the mount failed the checks above (a failed check after mounting unmounts it again) |
| `stale-mount` | A dead mount could not be cleaned up |
| `busy` | The lock file is held by another job, the folder is mounted elsewhere, or `lock` found it still in use |
| `not-locked` | `change-passphrase`, `destroy`, `purge`: the folder is unlocked (for `purge`: anything is mounted there) |
| `symlink`, `not-directory`, `not-owned` | Something in the way is a symlink, not a folder, or not yours; nothing is followed or deleted |
| `os-error` | Any other failure, including unexpected errors (no traceback is printed) |

The plasmoid accepts only these codes (plus `empty-passphrase`, which the
helper does not currently send because gocryptfs reports an empty passphrase
like a cancel). Any other code becomes `failed`; a non-zero exit or output
that is not one of the replies above becomes `bad-reply`. Every failure keeps
the Chat tab on its card or in the private session; nothing is saved.

gocryptfs exit codes are mapped as measured with gocryptfs 2.6.1: 12
`wrong-passphrase`; 9 `cancelled`; 10 `mount-failed`; 6 `absent` (`exists`
for `create`); 11 `absent`; 19 `busy` when a mount is present afterwards,
else `mount-failed`; anything else `init-failed` (`create`), `mount-failed`
(mount), or `os-error` (`change-passphrase`).
