# Privacy

AI Usage reads existing local sign-in state only for providers the user tracks
and that are detected as installed. Credentials are sent only to the matching
provider's first-party OAuth and usage endpoints.

The helper does not print or log access tokens, refresh tokens, API keys,
credential fingerprints, or raw provider responses. Its JSON output contains
only display metadata, quota percentages, billing summaries, plan names, and
timestamps.

Usage snapshots, stale readings, and rate-limit cooldowns live only in the
Plasma widget process. They disappear when Plasma restarts. AI Usage does not
read local chat transcripts and does not keep usage history.

Antigravity is the one provider that requires a derived access-token cache
because its Secret Service entry can contain only a refresh token. That cache
is written to `$XDG_CACHE_HOME/ai-usage-kde/antigravity-auth.json` (falling back
to `~/.cache`) with mode `0600`. It contains a short-lived access token, expiry,
and a SHA-256 refresh-token fingerprint. It never contains the refresh token.

When a credential file is a symlink, refreshed credentials are written to the
file it points to with mode `0600`, and only if that file already exists, is a
regular file, and is owned by the current user.

To keep two helper runs from refreshing the same token, the helper creates
empty lock files named `<provider>.lock` in `$XDG_RUNTIME_DIR/ai-usage-kde/`
(falling back to `<temp dir>/ai-usage-kde-<uid>/`). The directory is mode
`0700` and each file is mode `0600`. The files hold no data; only their
advisory lock is used.

To find CLIs and profile directories, the helper may start the user's login
shell once per run. That shell prints only the allow-listed variables
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `PATH`. The values stay in memory and are never cached to
disk.

AI Usage makes no network requests other than to the tracked providers'
endpoints and the chat websites you open, plus whatever those sites load. No
analytics or telemetry are collected.

## Chat tab

The Chat tab shows a provider's own website (Claude, ChatGPT, Grok, Gemini,
GitHub Copilot, or Microsoft Copilot) in Qt WebEngine inside the Plasma
process. You sign in on each site as you would in a browser. The design goal
is that anything you enter there (accounts, passwords, prompts, uploaded files,
cookies) stays in Plasma's memory, visible only to your session, and is gone
when Plasma restarts or you choose **Clear chat data**.

### Off-the-record profile

All chat pages, including sign-in windows, share one off-the-record Qt
WebEngine profile with an in-memory HTTP cache and no persistent cookies.
Qt WebEngine creates no profile directory for it. Cookies, sessions, local
storage, IndexedDB, service workers, history, and favicons exist only in
memory. Spell checking is off. You are therefore signed out on every Plasma
restart; persistent sign-in is not offered.

**Clear chat data** (in the Chat tab, after a confirmation) destroys every
chat page together with the profile, which signs you out of all chat sites at
once. Qt WebEngine is not started until you first open the Chat tab.

### What is stored where

| Data | Where it lives |
| --- | --- |
| Cookies, sessions, site storage, HTTP cache | Memory only; dropped on Clear chat data or Plasma restart |
| Page titles, addresses, history, icons | Memory only; the widget never shows, stores, or logs them |
| Passwords and form autofill | Not supported by Qt WebEngine; nothing is saved |
| Widget settings | Only the enabled sites (`chatSites`) and the first site (`chatDefaultSite`); no addresses or last page |
| Downloads | Only files you approve, saved to your Downloads folder |
| Uploads | Read-only, from files you pick in the file dialog |
| Page console messages | Discarded; never written to the journal |
| Links opened in your browser | Handed to your default browser, which may keep them in its history; the address briefly appears in that browser's process arguments |

The widget never runs scripts in, reads from, or injects anything into the
pages, sets no `QTWEBENGINE_*` variables or Chromium flags, and does not pass
chat data to the Python helper, process arguments, or the environment. Load
errors show generic text and are not logged. The system file dialog may
remember recently used folders, as it does for any application.

### Permissions and prompts

Every site permission request is denied: microphone, camera, screen sharing,
notifications, location, clipboard reading, mouse lock, and local fonts. There
is no per-site allow. Full-screen requests, HTTP authentication prompts, client
certificate requests, file-system access, and protocol-handler registration
are refused. Pages with certificate errors are not loaded. Passkey (WebAuthn)
sign-in is cancelled with the message "Passkeys aren't supported here; choose
another sign-in method."

Downloads ask each time: **Save "name" to Downloads?** Save writes the file to
your XDG Downloads folder; Cancel, or no answer within 60 seconds, discards it.
"Save page" downloads are always refused.

Clicked links that leave the chat site open in your default browser. The
widget hands the address to that browser, which may keep it in its history,
and the address briefly appears in the browser's process arguments. Only
links you click are handed over; windows a page opens by itself are dropped.
Sign-in popups stay inside the widget, in a sign-in overlay that uses the same
private profile. See [Provider contracts](provider-contracts.md#chat-tab) for the exact
navigation rules.

### Threat model

The Chat tab protects against:

- other local users, who cannot read Plasma's memory;
- the developer: there is no telemetry, the widget makes no requests of its
  own, and it never reads or changes the pages;
- leftovers on disk after a Plasma restart or Clear chat data;
- chat content in logs.

It does not protect against:

- root, or malware running as your user, which can read Plasma's memory;
- the chat providers themselves, and the third parties their pages load;
- swap, core dumps, or clipboard managers, unless configured as below.

### Recommended system settings

- Use full-disk encryption, or at least encrypted swap, so memory paged out
  to disk is not readable later.
- Disable stored core dumps (for systemd-coredump, set `Storage=none` in
  `/etc/systemd/coredump.conf`); a Plasma crash dump would contain chat pages.
- Text you copy is handled by your clipboard manager. If Klipper (or another
  clipboard manager) keeps its history across sessions, copied chat text may
  be written to disk. Pages cannot read the clipboard.
- Never set `QTWEBENGINE_REMOTE_DEBUGGING` for Plasma; it would expose every
  open page, including your sessions, to local connections.
