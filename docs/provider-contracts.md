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
and never calls an API, runs the helper, or reads the pages. Sites, their home
pages and host lists live only in `plasmoid/contents/ui/ChatSites.js`.

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
  the same private profile, and closes when the page closes it.
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
