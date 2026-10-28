# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) GLM Coding Plan quotas and token usage history.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window token usage (percentage) |
| Weekly | 7-day rolling window token usage (percentage) |
| Web Searches | Monthly web-search / web-reader / Zread calls (used / limit) |
| Today | Today's reported tokens and approximate API cost |
| Yesterday | Yesterday's reported tokens and approximate API cost |
| Last 30 Days | Tokens and approximate API cost across today plus the previous 30 calendar days |

When Z.ai reports your plan name, OpenUsage shows it beside the provider name.

History comes from your Z.ai account, including usage from other machines, and contributes to the
top **Tokens**, **Cost**, and **Cost/MTok** totals even when you hide the individual history rows.
Days with no reported usage show **No data**, matching the other providers' history rows.

The cost is an owner-selected approximation: every reported token is priced as **GLM-5.3 input**
through the shared pricing engine, currently **$1.40 per million tokens**. It applies that model's
rate to the whole history, including any other models the account previously used. Z.ai does not
separate input, output, and cached tokens in this response, so the estimate cannot apply their
different rates. The existing estimate notes explain this assumption. It is an approximate API
value, not a subscription bill. If GLM-5.3 pricing is unavailable, tokens still contribute to the
chart and a warning explains the missing cost.

## Where credentials come from

Z.ai has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API key.
OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

You can also add and rotate the key from **Settings → API Keys** without touching a file. Either
way, nothing leaves your Mac except the same API calls Z.ai's own subscription UI makes.

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list).
2. Add the key to OpenUsage via **Settings → API Keys**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. Z.ai appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

Three internal endpoints used by Z.ai's subscription UI and
[official usage-query plugin](https://github.com/zai-org/zai-coding-plugins):

- `GET https://api.z.ai/api/biz/subscription/list` — plan name (best-effort; a failure here doesn't
  blank the meters).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — the quota meters.
- `GET https://api.z.ai/api/monitor/usage/model-usage?startTime=…&endTime=…` — daily token history.
  OpenUsage requests the shared history window using local calendar dates and reads the returned
  daily buckets. The API's aggregate token counts already include every model.

The quota response carries a `limits` array. Each `CREDIT_LIMIT` entry (called `TOKENS_LIMIT` in
older responses) is a percentage quota window; its window length decides which meter it feeds
(sub-daily → Session, multi-day → Weekly), while a `TIME_LIMIT` entry is the monthly web-search
count. Reset times come back as epoch milliseconds. Missing required usage values are reported as
an invalid response instead of being shown as zero.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Settings → API Keys, or export `ZAI_API_KEY`.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [Z.ai console](https://z.ai/manage-apikey/apikey-list).
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe at [z.ai/subscribe](https://z.ai/subscribe);
  usage appears once your plan is active.
- **Meters show "No usage data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. Check your [plan](https://z.ai/manage-apikey/coding-plan/personal/my-plan).
- **"Couldn't load Z.ai usage history"** — the history request failed or returned an invalid response.
  The quota meters remain available; refresh to try the history request again.
