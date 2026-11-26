# Refreshing & Caching

## When data updates

- Enabled providers refresh at launch. After that, Claude checks every 10 minutes by default and the other providers check every 5 minutes. Change a provider's interval in **Settings → Automatic Refresh**. The choice applies immediately to all its accounts.
- Providers due together fetch in parallel. Fast cards update as results arrive, and nearby results are grouped into one update and save (adapted from Runway #47, MIT). Opening the popover leaves the schedule in place.
- Turning on a provider that hasn't been checked this session fetches it promptly, even during another refresh. A recent Claude check, including a failed attempt, counts toward its next automatic check.
- The Dashboard and Settings footer counts down to the next enabled provider's check. **Click the countdown or press ⌘R** to refresh immediately. A manual check starts a new interval for the providers it checks.
- The one-shot `openusage` command uses each provider's interval to decide when to reuse its saved data. `openusage --force` skips that freshness check, like ⌘R.
- While a provider is fetching, a small spinner appears next to its name (and one shows in the footer beside the countdown), so you can tell a refresh is in flight rather than wondering if the numbers are stale.
- With [iCloud Sync](icloud-sync.md) on, a refresh batch writes one machine-history file after the whole
  batch finishes. Manual provider refreshes write after that provider finishes, and adjacent changes are
  debounced into one write.

## Caching

Snapshots are cached on disk and load instantly at launch, so you see your last-known values immediately instead of placeholders — even before the first fetch finishes.

Claude and Codex cache entries also remember which account produced them. If you swap the account
signed in at the provider's default home between launches, the previous account's cached values are
discarded at the next launch (the card starts empty and fills on its first fetch) instead of briefly
showing the old account's limits and plan under the new login.

A cached value only counts as *fresh* (skip-a-refresh fresh) when it was fetched **during the current running session**. So a value cached in an earlier session always re-fetches on the first pass after launch — you still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new app version refreshes right away instead of showing the previous version's data until its interval lapses. Within a session, a freshly fetched value then counts as fresh for one refresh interval before the next pass re-fetches it.

Claude, Codex, and pi spend history has a separate local-log parse cache under
`~/Library/Application Support/OpenUsage/log-scan-cache/`. It stores parsed usage events before OpenUsage
applies model-rate estimates, so pricing updates take effect without re-reading unchanged JSONL. On
relaunch, a plain-log entry is reused only when its path, size, modification time, and parser version still match.
Codex compressed rollouts are immutable: their entries match by path, compressed size, and parser version.
They are streamed once and retained across history-window changes, so older archives are not repeatedly
decompressed. Their recorded event dates determine which usage falls inside the window.
When a supported JSONL file only grows, the scanner resumes from the last complete line and reads only
the appended bytes. A changed prefix, truncated file, incomplete appended line, or unusable parser state
falls back to a full streamed parse instead of dropping that record. Same-home cards share parsed data,
and changing one source file rewrites only that file's record. Old plain-log files leave the cache as the
history window advances; compressed-file entries are removed when their source is deleted. Identities
unused for 35 days are removed. App writes are debounced until after refresh; the one-shot CLI drains
pending writes before it exits.

The append-only scanner is adapted from Runway (mstallone/runway, MIT). The Codex line scan checks
event markers in one pass, also adapted from Runway #45.

## When a fetch fails

A failed refresh **never wipes your data**: the last good values stay on screen, and a small warning triangle appears next to the provider's name — hover it for the error message (e.g. "Not logged in"). The error clears on the next successful refresh.

When Anthropic rate-limits Claude, OpenUsage honors its retry delay, including on manual refreshes in the running app. If Anthropic omits the delay, OpenUsage waits 10 minutes. A longer delay can span several scheduled checks.

A provider that stops responding altogether is given up on after two minutes. Its spinner stops, the
warning triangle reads "Refresh timed out after 120s", and it is tried again on a later pass — so one
stuck provider can't leave a spinner turning for the rest of the session. The wait is deliberately long:
a healthy provider on a slow network can legitimately take over a minute, and it should be reported as
slow, not as broken.

The last good normalized history is preserved too, so a temporary provider failure—or a successful
limit refresh whose local log scan is temporarily unavailable—does not remove this Mac's previous
contribution from an iCloud-combined spend total.

Rows that have never had data show "No data" rather than made-up numbers.

## Keychain access

Some logins live in your macOS Keychain, and macOS asks before OpenUsage can read them.

- Choose **Always Allow** so later refreshes stay quiet.
- Each login shows one request at a time, and OpenUsage waits for your answer.
- If you choose **Deny**, OpenUsage stops asking for that login until you refresh manually.

## Stale data

An **Outdated** tag appears when a provider's displayed data reaches twice its selected interval. At the defaults, that's 20 minutes for Claude and 10 minutes for other providers. Hover over the tag for the age of the last successful update.
