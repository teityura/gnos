import boto3
import json
import re
import time
import urllib.request
from datetime import datetime, timezone

dynamodb = boto3.resource("dynamodb")
games_table = dynamodb.Table("gnos-games")
prices_table = dynamodb.Table("gnos-prices")


def lambda_handler(event, context):
    # [NOTE] crawler は見に行って記録するだけで、通知はしない。通知は notifier が毎日決まった時刻にまとめて送る
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

            # [NOTE] 価格が変わったときだけ履歴に1件足す。変化なしなら None が返る
            prev = record_if_changed(app_id, current_price, current_discount, now)
            if prev is not None and "latest_price" not in prev:
                print(f"初回記録: {name} ¥{current_price // 100:,}")
            elif prev is not None:
                print(f"価格変化: {name} ¥{prev['latest_price'] // 100:,} → ¥{current_price // 100:,}")

            # [NOTE] セール終了日時はストアページにしか無いので、セール中に1回だけ取りに行って覚えておく
            if current_discount > 0 and not game.get("sale_end_at"):
                sale_end_at = fetch_sale_end(app_id)
                if sale_end_at:
                    start_game_sale(app_id, sale_end_at)
                    print(f"セール終了日時を取得: {name} → {sale_end_at}")
            elif current_discount == 0 and game.get("sale_end_at"):
                end_game_sale(app_id)

        except Exception as e:
            print(f"Steam取得エラー: {name} ({app_id}): {e}")

    return {"statusCode": 200}


def record_if_changed(app_id, price, discount, now):
    """最新値を上書きし、価格が変わっていたときだけ履歴に足して更新前の値を返す。変化なしなら None"""
    # [NOTE] 上書きと「上書き前の値の取得」を1回で行う。1回の更新は不可分なので、読んでから書く2手と違い割り込まれない
    # [NOTE] 条件付き書き込みは弾かれても書き込み1回分の料金がかかるので使わない。この形なら変化なしのとき書き込みは1回で済む
    resp = games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="SET latest_price = :p, latest_discount = :d, checked_at = :t",
        ExpressionAttributeValues={":p": price, ":d": discount, ":t": now},
        ReturnValues="UPDATED_OLD",
    )
    old = resp.get("Attributes", {})
    # [NOTE] checked_at は毎回更新されるので、巡回が止まっていないかを最後に見に行った時刻で確かめられる
    if old.get("latest_price") == price:
        return None

    prices_table.put_item(Item={
        "app_id": app_id,
        "checked_at": now,
        "price": price,
        "discount": discount,
    })
    # [NOTE] UPDATED_OLD は更新前の値を返す。latest_price が含まれなければ初回
    return old


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


def start_game_sale(app_id, sale_end_at):
    """セールの終了日時を覚え、終了前の警告をまだ出していない状態にする"""
    games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="SET sale_end_at = :e, sale_end_notified = :n",
        ExpressionAttributeValues={":e": sale_end_at, ":n": False},
    )


def end_game_sale(app_id):
    """セールが終わったので、終了日時と警告済みの印を消す"""
    games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="REMOVE sale_end_at, sale_end_notified",
    )


def pick_app(data, app_id):
    """appdetails の応答から、要求した app_id のゲームを取り出す。無ければ None"""
    # [NOTE] 2026-09-24 頃から Steam は要求と別の ID をキーにして返すことがある。1件だけ要求しているので、キーではなく中身の steam_appid で確かめる
    for app in (data or {}).values():
        if app.get("success") and str(app["data"].get("steam_appid")) == str(app_id):
            return app
    return None


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
            app = pick_app(json.loads(res.read()), app_id)
            if not app:
                print(f"Steam応答に該当なし: {app_id}")
                return None
            return app["data"].get("price_overview")
        except Exception as e:
            if attempt < retries - 1:
                print(f"fetch_price retry {attempt + 1}/{retries - 1}: {app_id} ({e})")
                time.sleep(delay)
            else:
                raise
