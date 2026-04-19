import boto3
import json
import time
import urllib.request
from datetime import datetime, timezone

DISCORD_WEBHOOK = ""  # variables.tf から環境変数で注入

dynamodb = boto3.resource("dynamodb")
games_table = dynamodb.Table("gnos-games")
prices_table = dynamodb.Table("gnos-prices")


def lambda_handler(event, context):
    webhook = DISCORD_WEBHOOK or _env("DISCORD_WEBHOOK")

    games = games_table.scan()["Items"]

    for game in games:
        app_id = game["app_id"]
        name = game.get("name", app_id)

        try:
            price_info = fetch_price(app_id)
            if not price_info:
                continue

            now = datetime.now(timezone.utc).isoformat()
            current_price = price_info["final"]
            current_discount = price_info["discount_percent"]

            # 前回価格を取得（書き込み前に取得することで「今回 vs 前回」を明確にする）
            prev = get_last_price(app_id)

            # 価格を記録
            prices_table.put_item(Item={
                "app_id": app_id,
                "checked_at": now,
                "price": current_price,
                "discount": current_discount,
            })

            if prev is None:
                print(f"初回記録: {name} ¥{current_price // 100:,}")
                continue  # 比較対象なし。次回から通知対象

            prev_price = prev["price"]
            prev_discount = prev["discount"]

            # 価格変動なし
            if current_price == prev_price:
                continue

            is_lowest = current_price <= get_min_price(app_id)
            lowest_tag = "\n🏆 **過去最安値更新！**" if is_lowest else ""

            # セール開始
            if current_discount > 0 and prev_discount == 0:
                message = (
                    f"🎮 **{name}** セール中！\n"
                    f"~~¥{price_info['initial'] // 100:,}~~ → "
                    f"¥{current_price // 100:,} "
                    f"({current_discount}%OFF)"
                    f"{lowest_tag}\n"
                    f"https://store.steampowered.com/app/{app_id}/"
                )

            # セール終了
            elif current_discount == 0 and prev_discount > 0:
                message = (
                    f"📊 **{name}** 通常価格に戻りました\n"
                    f"¥{prev_price // 100:,} → ¥{current_price // 100:,}"
                )

            # その他の価格変動
            else:
                message = (
                    f"💰 **{name}** 価格変動\n"
                    f"¥{prev_price // 100:,} → ¥{current_price // 100:,}"
                    f"{lowest_tag}\n"
                    f"https://store.steampowered.com/app/{app_id}/"
                )

            try:
                notify(webhook, message)
            except Exception as e:
                print(f"Discord通知エラー: {name} ({app_id}): {e}")

        except Exception as e:
            print(f"Steam取得エラー: {name} ({app_id}): {e}")

    return {"statusCode": 200}


def fetch_price(app_id, retries=3, delay=5):
    """Steam API から価格情報を取得（403 時はリトライ）"""
    url = (
        f"https://store.steampowered.com/api/appdetails"
        f"?appids={app_id}&cc=JP&l=japanese"
    )
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            res = urllib.request.urlopen(req, timeout=10)
            data = json.loads(res.read())
            app = data.get(str(app_id))
            if not app or not app.get("success"):
                return None
            return app["data"].get("price_overview")
        except Exception as e:
            if attempt < retries - 1:
                print(f"fetch_price retry {attempt + 1}/{retries - 1}: {app_id} ({e})")
                time.sleep(delay)
            else:
                raise


def get_min_price(app_id):
    """gnos-prices から過去最安値を返す（現在書き込み済みの全履歴が対象）"""
    resp = prices_table.query(
        KeyConditionExpression="app_id = :id",
        ExpressionAttributeValues={":id": app_id},
    )
    prices = [item["price"] for item in resp.get("Items", []) if item.get("price") is not None]
    return min(prices) if prices else float("inf")


def get_last_price(app_id):
    """gnos-prices から最新の1件を返す"""
    resp = prices_table.query(
        KeyConditionExpression="app_id = :id",
        ExpressionAttributeValues={":id": app_id},
        ScanIndexForward=False,
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0] if items else None


def notify(webhook, message):
    """Discord Webhook に通知"""
    payload = json.dumps({"content": message}).encode()
    req = urllib.request.Request(
        webhook,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        },
    )
    urllib.request.urlopen(req)
    print(f"通知送信: {message[:60]}...")


def _env(key):
    """環境変数から取得"""
    import os
    return os.environ.get(key, "")
