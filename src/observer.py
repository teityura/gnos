import boto3
import json
import re
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

            # 書き込み前に取得して「今回 vs 前回」を確定させる
            prev = get_last_price(app_id)

            prices_table.put_item(Item={
                "app_id": app_id,
                "checked_at": now,
                "price": current_price,
                "discount": current_discount,
            })

            # 一覧表示用の非正規化。無いと gnos-api が全ゲーム分 query する羽目になる
            games_table.update_item(
                Key={"app_id": app_id},
                UpdateExpression="SET latest_price = :p, latest_discount = :d",
                ExpressionAttributeValues={":p": current_price, ":d": current_discount},
            )

            if prev is None:
                print(f"初回記録: {name} ¥{current_price // 100:,}")
                continue  # 比較対象なし。次回から通知対象

            prev_price = prev["price"]
            prev_discount = prev["discount"]

            if current_price != prev_price:
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
                    reset_game_sale(app_id)

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

            # セール中 → 24h前通知チェック（価格変動の有無に関わらず毎回）
            if current_discount > 0:
                try:
                    check_sale_end(game, app_id, name, current_price, current_discount, webhook)
                except Exception as e:
                    print(f"セール終了通知エラー: {name} ({app_id}): {e}")

        except Exception as e:
            print(f"Steam取得エラー: {name} ({app_id}): {e}")

    return {"statusCode": 200}


def check_sale_end(game, app_id, name, current_price, current_discount, webhook):
    """セール終了24h前に1回だけ通知する"""
    sale_end_at = game.get("sale_end_at")
    sale_end_notified = game.get("sale_end_notified", False)

    # sale_end_at が未取得の場合はストアページから取得して保存
    if not sale_end_at:
        sale_end_at = fetch_sale_end(app_id)
        if sale_end_at:
            update_game_sale(app_id, sale_end_at, False)
            print(f"セール終了日時を取得: {name} → {sale_end_at}")
        else:
            return  # 取得できなければスキップ

    if sale_end_notified:
        return  # 通知済み

    end_dt = datetime.fromisoformat(sale_end_at)
    now = datetime.now(timezone.utc)
    hours_left = (end_dt - now).total_seconds() / 3600

    if 0 < hours_left <= 24:
        h = int(hours_left)
        m = int((hours_left - h) * 60)
        try:
            notify(webhook,
                f"⏰ **{name}** のセールが間もなく終了！\n"
                f"残り約{h}時間{m}分\n"
                f"¥{current_price // 100:,} ({current_discount}%OFF)\n"
                f"https://store.steampowered.com/app/{app_id}/"
            )
            update_game_sale(app_id, sale_end_at, True)
        except Exception as e:
            print(f"Discord通知エラー: {name} ({app_id}): {e}")


def fetch_sale_end(app_id):
    """ストアページから終了日時を取得して ISO 8601 で返す"""
    url = f"https://store.steampowered.com/app/{app_id}/?l=english"
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0",
        "Cookie": "birthtime=631152001; lastagecheckage=1-January-1990; wants_mature_content=1",
    })
    res = urllib.request.urlopen(req, timeout=10)
    html = res.read().decode("utf-8", errors="ignore")

    m = re.search(r'game_purchase_discount_countdown[^>]*>[^<]*Offer ends (\d+ \w+)', html)
    if not m:
        return None

    date_str = m.group(1)  # 例: "27 April"
    year = datetime.now(timezone.utc).year
    try:
        dt = datetime.strptime(f"{date_str} {year}", "%d %B %Y")
        dt = dt.replace(tzinfo=timezone.utc)
        # 日付が過去なら来年
        if dt < datetime.now(timezone.utc):
            dt = dt.replace(year=year + 1)
        return dt.isoformat()
    except ValueError:
        return None


def update_game_sale(app_id, sale_end_at, sale_end_notified):
    """gnos-games に sale_end_at と sale_end_notified を書き込む"""
    games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="SET sale_end_at = :e, sale_end_notified = :n",
        ExpressionAttributeValues={
            ":e": sale_end_at,
            ":n": sale_end_notified,
        },
    )


def reset_game_sale(app_id):
    """セール終了時に sale_end_at / sale_end_notified をリセット"""
    games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="REMOVE sale_end_at, sale_end_notified",
    )


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
