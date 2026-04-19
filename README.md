# gnos

Steam game price monitor with Discord notifications.

Tracks prices every 3 hours and notifies you on changes or all-time lows.

## Stack

- **Lambda** — API handler (`gnos-gateway`) and price checker (`gnos-observer`)
- **DynamoDB** — watchlist and price history
- **API Gateway** — HTTP endpoints
- **S3** — static site hosting
- **EventBridge** — scheduled trigger (every 3h)

## API

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | /games | — | Watchlist with latest prices |
| GET | /history | — | Price history for a game |
| GET | /search | — | Search Steam games |
| POST | /add | x-api-key | Add game to watchlist |
| DELETE | /games | x-api-key | Remove game and its history |

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars  # fill in discord_webhook_url
terraform init
terraform apply
```
