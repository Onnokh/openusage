# Claude via CLIProxyAPI

Shows one Claude card for each Claude account you have logged in to [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI). Use it to watch the limits of several Claude accounts side by side.

## What it tracks

Each card is named after the account's email, for example **Claude · onno**. The plan shows next to the name, for example **Max 20x** or **Pro**, the same as on the main Claude card.

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
| Extra Usage | Extra-usage credits spent against your monthly cap |

These cards have no Today / Yesterday / Last 30 Days tiles. Those come from local Claude Code logs, which can't be split per account. The main **Claude** card still shows them.

## Where credentials come from

OpenUsage reads the `claude-*.json` files in CLIProxyAPI's auth folder. It finds the folder from `auth-dir` in the first config that exists:

1. `/opt/homebrew/etc/cliproxyapi.conf` (Homebrew)
2. `/usr/local/etc/cliproxyapi.conf`
3. `~/.cli-proxy-api/config.yaml`

If no config sets `auth-dir`, it uses `~/.cli-proxy-api`.

Accounts are found when OpenUsage starts. **Restart OpenUsage after you add or remove an account in CLIProxyAPI.**

OpenUsage **never refreshes these tokens**. CLIProxyAPI owns them, and a refresh from OpenUsage would log the account out of the proxy. OpenUsage re-reads the file on every refresh, so it picks up each new token as soon as CLIProxyAPI writes it.

## Troubleshooting

- **"Token expired. Waiting for CLIProxyAPI to refresh it."** — make sure CLIProxyAPI is running. It refreshes tokens before they expire.
- **"Token rejected."** — log in to that account again in CLIProxyAPI.
- **"Account is disabled in CLIProxyAPI."** — enable the account in CLIProxyAPI, or turn the card off in Settings.
- **"Account is no longer in CLIProxyAPI."** — the account file is gone. Restart OpenUsage to remove the card.
- **Rate limited** — same as the main Claude card: OpenUsage keeps your last values and shows when to expect new data.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the account's access token from CLIProxyAPI, on every refresh.

`GET https://api.anthropic.com/api/oauth/profile` with the same token, once per account, for the plan name. CLIProxyAPI's account file does not store the plan. If this request fails, the card shows no plan, and OpenUsage tries again on the next refresh.
