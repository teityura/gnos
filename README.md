# gnos

Steam game price monitor with Discord notifications.

Tracks prices every 3 hours and notifies you on sales, all-time lows, and sales about to end.
Price history is kept in DynamoDB; games can be added, removed and charted from the web UI.

## Stack

| Resource | Name | Role |
|---|---|---|
| Lambda | `gnos-observer` | Price checker, history writer, Discord notifier |
| Lambda | `gnos-api` | HTTP API, exposed via Function URL |
| EventBridge | `gnos-schedule` | Triggers observer every 3h |
| DynamoDB | `gnos-games` | Watchlist |
| DynamoDB | `gnos-prices` | Price history (PK `app_id` / SK `checked_at`) |
| S3 | `gnos-site` | Static site |
| IAM | `gnos-lambda-role` | Lambda execution role |
| IAM | `gnos-guardrail` | Accidental-deletion guardrail |
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

## Notifications

- Sale started / ended / other price changes
- All-time low
- 24 hours before a sale ends (once per sale)

## Usage

```bash
make setup     # create secrets.auto.tfvars from the sample, then init
               # -> fill in discord_webhook_url and api_keys
make           # deploy (init + apply)
make plan      # show diff
make backup    # dump DynamoDB tables to backup/<timestamp>/
make clean     # destroy + remove local state
```

`make clean` deletes the state file. **Without state, neither apply nor destroy works**
and every resource has to be recovered one by one with `terraform import`.
Use it only when tearing the project down for good.

## Deletion protection

Three layers, none of which enumerate projects:

| layer | where | covers |
|---|---|---|
| tag deny | aws-ops (`sweeper-guardrail`) | anything with a `Project` tag, any value |
| bucket policy | this repo | S3, where tag conditions do not work |
| native flag | `deletion_protection_enabled` | DynamoDB tables, against every principal |

`default_tags` stamps `Project` / `ManagedBy` on every taggable resource, so a new
resource is protected without touching any policy. The bucket policy also denies
`PutBucketPolicy` / `DeleteBucketPolicy` for everyone but the Terraform principal,
so it cannot be stripped first and deleted after.

## Design notes

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

Under $0.000001/month across the whole account. DynamoDB is on-demand; Lambda and Function
URLs stay in the free tier. Only S3 storage is billed, in fractions of a cent.

## Requirements

- Terraform 1.12+
- AWS CLI v2
