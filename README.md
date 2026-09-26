# gnos

Watches Steam prices and tells Discord when they change.
https://gnos.teityura.com

## How it works

```
every hour   crawler    checks Steam, records the price only when it changed
11:00 JST    notifier   posts every game whose price changed since the last post
web UI       api        add / archive / delete games, price history charts
```

## Using it

- Search a game and add it. Adding, archiving and deleting need an API key.
- Archiving stops notifications but keeps tracking the price. Restoring brings it back.
- Deleting is only possible from the archive. It removes the game and its history for good.

## Deploy

```bash
make setup     # create terraform/secrets.auto.tfvars from the sample
               # -> fill in discord_webhook_url and users
make           # deploy
make plan      # show diff
make backup    # dump DynamoDB tables to backup/<timestamp>/
make clean     # destroy everything and delete the state. There is no way back
```

To add a user, add a line to `users` in `secrets.auto.tfvars` and run `make`.

## Resources

| Name | What |
|---|---|
| `gnos-crawler` / `gnos-notifier` / `gnos-api` | Lambda |
| `gnos-crawl` / `gnos-notify` | EventBridge Scheduler |
| `gnos-games` / `gnos-prices` | DynamoDB: watchlist / price changes |
| `gnos-site` | S3: web UI |

Plus IAM roles and log groups. The domain is served by nginx on a Sakura VPS, outside Terraform.

Design notes, cost and diagrams are on the wiki.

## Requirements

- Terraform 1.12+
- AWS CLI v2
