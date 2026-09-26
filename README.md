# gnos

Steam game price monitor with Discord notifications.

Checks prices every hour and sends one Discord digest a day (11:00 JST) covering every game
whose price changed since the last digest. Price history is kept in DynamoDB, one row per change;
games can be added, removed and charted from the web UI.

## Stack

| Resource | Name | Role |
|---|---|---|
| Lambda | `gnos-crawler` | Price checker and history writer, no notifications |
| Lambda | `gnos-notifier` | Daily Discord digest |
| Lambda | `gnos-api` | HTTP API, exposed via Function URL |
| EventBridge Scheduler | `gnos-crawl` / `gnos-notify` | Hourly crawl / daily digest |
| DynamoDB | `gnos-games` | Watchlist, latest and last-notified price per game |
| DynamoDB | `gnos-prices` | Price history, change log only (PK `app_id` / SK `checked_at`) |
| S3 | `gnos-site` | Static site |
| IAM | `gnos-lambda-role` | Lambda execution role |
| IAM | `gnos-scheduler-role` | Lets the schedules invoke crawler and notifier |
| CloudWatch Logs | `/aws/lambda/gnos-*` | 30 day retention |

Public URL is `https://gnos.teityura.com` — nginx on a Sakura VPS reverse-proxies S3.
The domain is outside AWS and not managed by Terraform.

## API

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/games` | — | Watchlist with latest prices |
| GET | `/history?app_id=` | — | Price history for a game |
| GET | `/search?q=` | — | Search Steam games |
| POST | `/add` | `x-api-key` | Add game to watchlist |
| DELETE | `/games?app_id=` | `x-api-key` | Remove game and its history |

Auth is a plain lookup in `api.py` against the `API_KEYS` environment variable
(a JSON map of key → username). Reads are open; writes require a key.

Users are defined once, in the `users` variable (username → `api_key`, optional `discord_id`).
Terraform derives both `API_KEYS` and `DISCORD_USER_IDS` from it, so a username cannot be
spelled differently in two places. The username is stored as `added_by`, so do not rename it.

## Notifications

- Sale started / ended / other price changes, compared with the last digest
- All-time low
- 24 hours before a sale ends (once per sale)

Each entry links to the Steam store page and the gnos history page, and mentions the Discord
user who added the game, if that user has a `discord_id` in `users`.

A game gets its baseline when it is added (or on the first digest after this was introduced),
so nothing is sent for it until its price moves.

## Usage

```bash
make setup     # create secrets.auto.tfvars from the sample, then init
               # -> fill in discord_webhook_url and users
make           # deploy (init + apply)
make plan      # show diff
make backup    # dump DynamoDB tables to backup/<timestamp>/
make clean     # destroy + remove local state
```

`make clean` deletes the state file. **Without state, neither apply nor destroy works**
and every resource has to be recovered one by one with `terraform import`.
Use it only when tearing the project down for good.

## Deletion protection

Two layers, neither of which enumerates projects:

| layer | where | covers |
|---|---|---|
| tag deny | aws-ops (`sweeper-guardrail`) | anything with a `Project` tag, any value |
| bucket policy | this repo | S3, where tag conditions do not work |

DynamoDB tables have no native deletion protection; `make clean` has to be able to destroy them.
Use `make backup` before anything risky.

`default_tags` stamps `Project` / `ManagedBy` on every taggable resource, so a new
resource is protected without touching any policy. The bucket policy also denies
`PutBucketPolicy` / `DeleteBucketPolicy` for everyone but the Terraform principal,
so it cannot be stripped first and deleted after.

## Design notes

**History is a change log, not a sample log.**
The crawler writes a `gnos-prices` row only when the price differs from `latest_price` in
`gnos-games`. It does this with a single `UpdateItem` (`ReturnValues="UPDATED_OLD"`) that
overwrites the latest value and returns the previous one, so there is no read-then-write race.
A conditional write was rejected: a failed condition is still billed as a write.
The notifier uses the same shape — `notified_price` against `latest_price`.
The history chart draws steps (`stepped: "after"`), so gaps between rows mean "unchanged".

**Crawl and notify are separate functions on separate schedules.**
The crawler has no Discord settings at all. EventBridge Scheduler takes a time zone, so the
digest time is written as 11:00 in `Asia/Tokyo` rather than converted to UTC.
DynamoDB Streams was considered for triggering notifications, but a daily digest needs a
schedule anyway.

**Steam's `appdetails` response is not keyed by the requested ID.**
Since around 2026-09-24 the top-level key is sometimes a different ID. The code takes the
entry whose `data.steam_appid` matches instead of indexing by key.

**Lambda Function URL instead of API Gateway.**
`api.py` routes on `rawPath` itself, so only an HTTP entry point is needed. Function URLs are
free and their ARN contains the function name, which lets the guardrail cover them —
an API Gateway ARN is `/apis/<id>` and carries no name.

**A public Function URL needs two permissions.**
AWS accounts created from 2024 onward block public Function URLs by default, and
`lambda:InvokeFunctionUrl` alone returns `403 AccessDeniedException`.
`lambda:InvokeFunction` with `Principal="*"` must be granted as well.

**CORS is configured only on the Function URL.**
Returning CORS headers from `api.py` as well duplicates them, which browsers reject —
and `curl` still shows 200, so it is easy to miss.

## Cost

Effectively zero. DynamoDB is provisioned inside the always-free 25 WCU / 25 RCU (on-demand
is not covered by the free tier, and the free capacity is shared by every table in the region).
Lambda, Function URLs, EventBridge Scheduler and CloudWatch Logs stay well inside their free
tiers. Only S3 storage is billed, in fractions of a cent.

## Requirements

- Terraform 1.12+
- AWS CLI v2
