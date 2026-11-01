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
and never calls an API or reads the pages. The one exception is the built-in
Ollama chat, which calls the local Ollama API (see
[below](#built-in-ollama-chat)). It runs the helper only for Stay signed in
(see [below](#stay-signed-in-helper)) and for the Ollama port check (see
[below](#port-owner-helper)), never with chat data. Web sites, their home
pages and host lists live only in `plasmoid/contents/ui/ChatSites.js`. The
navigation rules below are the same with Stay signed in Off or Encrypted.

| Site | Home page | Site hosts | Sign-in hosts |
| --- | --- | --- | --- |
| Claude | `https://claude.ai/new` | claude.ai, claude.com, anthropic.com | accounts.google.com, appleid.apple.com |
| ChatGPT | `https://chatgpt.com/` | chatgpt.com, openai.com | accounts.google.com, login.microsoftonline.com, login.live.com, appleid.apple.com |
| Grok | `https://grok.com/` | grok.com, x.ai, x.com | accounts.google.com, appleid.apple.com |
| Gemini (best effort) | `https://gemini.google.com/app` | gemini.google.com, accounts.google.com, consent.google.com | accounts.google.com |
| GitHub Copilot | `https://github.com/login?return_to=%2Fcopilot` | github.com | github.com, accounts.google.com, appleid.apple.com |
| Microsoft Copilot | `https://copilot.microsoft.com/` | copilot.microsoft.com, microsoft.com, bing.com | login.microsoftonline.com, login.live.com, account.live.com, accounts.google.com, appleid.apple.com |
| Local web UI (Open WebUI), off by default | `http://localhost:3000/` | localhost, 127.0.0.1, [::1] | none |

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

### Built-in Ollama chat

"Ollama" (id `ollama`, off by default) is not a web site and is not in
`ChatSites.js`: `plasmoid/contents/ui/OllamaChat.js` holds its entry and all
parsing, and `OllamaChatView.qml` makes the requests with QML
`XMLHttpRequest` (the only file that does). `chatSites` may contain `ollama`,
and `chatDefaultSite` may be `ollama`; the dropdown lists it after the web
sites. The web view never gets `ollama` as a site and does not start while
Ollama is shown.

Address (`chatOllamaUrl`, String, default `http://127.0.0.1:11434`, written
only by the settings page):

- Exactly `http://<host>:<port>` with an optional trailing `/`, at most 64
  characters, saved normalized as `http://host:port`. `host` is `127.0.0.1`,
  `localhost`, or `[::1]` (any case), nothing else: no other `127.x` address,
  `0.0.0.0`, numeric spellings such as `2130706433` or `0x7f000001`,
  `*.localhost`, or names that resolve to loopback. `port` is 1 to 65535 and
  must be given.
- Refused, with these codes: `too-long`, `whitespace` (also control
  characters), `userinfo`, `scheme` (anything but `http`), `not-loopback`,
  `port-missing`, `port-range`, `path` (any path, query or fragment),
  `malformed`. Empty text means the default. While the field holds invalid
  text the value saved when the page opened stays saved. A config value that
  doesn't validate is replaced by the default when used.

Requests, all to the configured address, nothing in the URL but the path:

| Request | When | Body |
| --- | --- | --- |
| `GET /api/version` | The Ollama view is shown, after the owner check | none |
| `GET /api/tags` | After a valid version reply | none |
| `POST /api/chat` | Send, after its own owner check | `{"model":m,"messages":[{"role":"user"\|"assistant","content":s},…],"stream":true}` |
| `POST /api/chat` | Clear conversation, once per model used, after an owner check | `{"model":m,"messages":[],"keep_alive":0}` (unloads the model) |

The only header set is `Content-Type: application/json` (POST only); no
credentials, cookies or `Authorization`, and Qt's XMLHttpRequest sends no
`Origin` header (Ollama answers 403 to a foreign `Origin`). Nothing is
requested until Ollama is enabled and shown in the open popup, and there is no
polling: the list is loaded when the view is shown while it isn't loaded yet
(also after a failure), on **Retry** or **Reload models**, and when the
address changes. Each turn sends the whole
conversation; prompts are at most 32000 characters (Send is disabled above
that).

Replies:

- `/api/version` must be status 200 with a JSON object whose `version`
  matches `^\d+\.\d+` (at most 32 characters); anything else is "Something
  other than Ollama is answering at this address." and nothing more is sent.
- `/api/tags`: `models[]` in server order, at most 200. A model is kept when
  its `name` matches `^[A-Za-z0-9._:/+-]{1,200}$`. Dropped and counted as
  hidden: entries with `remote_host` or `remote_model`, or names ending in
  `:cloud` or `-cloud` (cloud models forward prompts to ollama.com). Dropped
  silently: entries whose `capabilities` exists but lacks `completion`
  (embedding models) and duplicates. `details.parameter_size` and `family`
  are shown only when they are short plain words. The model choice is
  runtime only: the previous choice while it is still listed, else the first.
- `/api/chat` streams NDJSON. Only complete `\n`-terminated lines are read
  (plus the last line when the reply ends); blank lines are skipped. For each
  object, `message.content` is appended; `message.thinking` only shows
  "Thinking…" and its text is discarded; `done: true` ends the reply; an
  `error` string ends it as a server error. A line that isn't a JSON object
  ends it as unreadable. Replies are cut at 200000 characters (the request is
  aborted and the text kept). Unknown fields are ignored.
- Server error text is shown only as plain text, at most 300 characters,
  with control characters, bidi controls and `<`, `>`, `&` removed.

Status handling: 0 (connection refused) "Ollama isn't running."; 403
"Ollama refused the request."; 404 on chat "This model isn't installed any
more."; anything else non-2xx a generic error plus the server's `error`
text. No first byte within 300 s (a model can take minutes to load on a CPU)
or no data for 120 s aborts with "Ollama stopped responding." Stop and Esc
abort the request; a reply that was already partly shown is kept and marked
stopped. Late events of any aborted or finished request are ignored.

Owner check (see [below](#port-owner-helper)): `none` is "Ollama isn't
running.", `other` "Another user's program is using port N. Hearthside won't
send anything to it.", any failure or a check that takes over 15 s
"Couldn't check which program is using port N."; only `self` and `system`
let a request through. Error texts never show the address, only its port.

Redirects: Qt's XMLHttpRequest follows HTTP redirects on its own, including
to another host or port, and repeats a POST body there; JavaScript never sees
the 3xx (measured with Qt 6.12.0 for 302 and 307). From readyState 3 on,
`responseURL` holds the address that actually answered, so every reply is
checked against the exact `OllamaChat.endpoint()` it was sent to. On the
first mismatch the request is aborted and nothing from it is read: a
redirected `/api/version` or `/api/tags` is "Something other than Ollama is
answering at this address." (no model list, nothing can be sent), a
redirected `/api/chat` ends as "Ollama reported an error." with no reply text
and no server error text shown.

Limits: by the time a redirect is seen, Qt has already sent the request to
the new address, so a trusted listener (one that passed the owner check) that
answers `/api/version` and `/api/tags` normally but redirects only
`POST /api/chat` still hands the prompt to wherever it points, possibly
another computer. That is the same trust as in a listener that proxies the
request onward itself; the owner check covers only the configured port. An
unload request (no prompt) is sent the same way and its reply is never read.
The check also cannot tell programs of your own user apart. While a reply
streams, it is read at most every 100 ms (Qt decodes the whole body again on
each read), and once more when it ends.

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

## Port owner helper

Before the built-in Ollama chat loads the model list or sends a message, the
plasmoid asks the helper who listens on the Ollama port, so a prompt never
goes to another user's program that took the port while Ollama was down. The
command is built in `plasmoid/contents/ui/OllamaChat.js` from integers only:

    env HEARTHSIDE_RUN=<n> HEARTHSIDE_APPLET=<applet> python3 -m hearthside --port-owner <port>

The env words only keep DataSource names unique (as for the Stay signed in
helper); the helper ignores them. The command carries no prompt, model name,
or address, touches no credentials, and makes no network request.

- Reads only `/proc/net/tcp` and `/proc/net/tcp6`; opens no socket and starts
  no program (`src/hearthside/core/portowner.py`).
- Counts sockets in state LISTEN (`0A`) on `<port>` whose local address a
  connection to `127.0.0.1`, `localhost`, or `[::1]` can reach: `127.0.0.1`,
  `0.0.0.0`, `::1`, `::`, `::ffff:127.0.0.1`, `::ffff:0.0.0.0`. Other bind
  addresses (for example `127.0.0.2` or a LAN address) and connections in any
  other state are ignored.
- Trusted owners are your own uid, root (uid 0), and the system `ollama`
  account when that user exists (`getpwnam("ollama")`).
- A missing `/proc/net/tcp6` (kernel without IPv6) counts as no IPv6 sockets.
  A missing or unreadable `/proc/net/tcp`, an unreadable `tcp6`, or any line
  that does not parse gives `unreadable`, never `none`.

Reply (one JSON object on stdout, exit 0):

| Reply | Meaning |
| --- | --- |
| `{"ok":true,"owner":"none"}` | Nothing listens there |
| `{"ok":true,"owner":"self"}` | Every listener is yours |
| `{"ok":true,"owner":"system"}` | Every listener is trusted and at least one is root or `ollama` (the packaged `ollama.service`) |
| `{"ok":true,"owner":"other"}` | At least one listener belongs to another user |
| `{"ok":false,"error":"unreadable"}` | The tables could not be read or parsed, or anything unexpected happened |

Replies never contain uids, user names, inodes, or addresses. `<port>` is a
plain decimal integer from 1 to 65535 (at most 5 digits; no sign, spaces, or
underscores), and `--port-owner` cannot be combined with any other option;
otherwise argparse exits 2 with a usage message on stderr and prints nothing on
stdout. The plasmoid sends only for `self` or `system` and fails closed on
everything else, including a non-zero exit or any other output (`bad-reply`).
The check cannot tell your own programs apart, and a listener could change in
the milliseconds between the check and the request; see `docs/privacy.md`.
