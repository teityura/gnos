import boto3
import json
import os
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from decimal import Decimal

dynamodb = boto3.resource("dynamodb")
games_table = dynamodb.Table("gnos-games")
prices_table = dynamodb.Table("gnos-prices")

DISCORD_WEBHOOK = ""  # 環境変数で注入


def get_api_keys():
    """API_KEYS 環境変数（JSON）からキー→ユーザー名マップを返す"""
    return json.loads(os.environ.get("API_KEYS", "{}"))


def authenticate(event):
    """x-api-key ヘッダーを検証し、対応するユーザー名を返す。無効なら None"""
    key = (event.get("headers") or {}).get("x-api-key", "")
    return get_api_keys().get(key)


def lambda_handler(event, context):
    webhook = DISCORD_WEBHOOK or os.environ.get("DISCORD_WEBHOOK", "")
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")
    params = event.get("queryStringParameters") or {}

    try:
        if method == "POST" and path == "/add":
            return handle_add(event, webhook)
        elif method == "GET" and path == "/games":
            return handle_games()
        elif method == "GET" and path == "/history":
            return handle_history(params)
        elif method == "GET" and path == "/search":
            return handle_search(params)
        elif method == "DELETE" and path == "/games":
            return handle_delete(event, params)
        else:
            return response(404, {"error": "not found"})
    except Exception as e:
        print(f"Error: {e}")
        return response(500, {"error": str(e)})


def handle_add(event, webhook):
    """ゲームを追加"""
    username = authenticate(event)
    if not username:
        return response(403, {"error": "invalid api key"})

    body = json.loads(event.get("body", "{}"))
    app_id = str(body.get("app_id", "")).strip()
    added_by = username

    if not app_id:
        return response(400, {"error": "app_id is required"})

    # 既に登録済みか確認
    existing = games_table.get_item(Key={"app_id": app_id}).get("Item")
    if existing:
        return response(409, {
            "error": "already exists",
            "name": existing.get("name"),
        })

    # Steam API からゲーム名と価格を取得
    steam = fetch_steam_info(app_id)
    if not steam:
        return response(404, {"error": "game not found on Steam"})

    name = steam["name"]
    now = datetime.now(timezone.utc).isoformat()

    # gnos-games に追加
    games_table.put_item(Item={
        "app_id": app_id,
        "name": name,
        "added_by": added_by,
        "added_at": now,
    })

    # gnos-prices に初回価格を記録
    price = steam.get("price_overview")
    if price:
        prices_table.put_item(Item={
            "app_id": app_id,
            "checked_at": now,
            "price": price["final"],
            "discount": price["discount_percent"],
        })

    # Discord に通知（失敗しても登録は成功扱い）
    if webhook:
        try:
            current = f"¥{price['final'] // 100:,}" if price else "無料"
            notify(webhook,
                f"✅ **{name}** をウォッチリストに追加しました (by {added_by})\n"
                f"現在価格: {current}\n"
                f"https://store.steampowered.com/app/{app_id}/"
            )
        except Exception as e:
            print(f"Discord通知失敗（無視）: {e}")

    return response(200, {"status": "ok", "name": name, "app_id": app_id})


def handle_delete(event, params):
    """ゲームを削除し、関連する価格履歴もまとめて消す"""
    if not authenticate(event):
        return response(403, {"error": "invalid api key"})

    app_id = params.get("app_id", "").strip()
    if not app_id:
        return response(400, {"error": "app_id is required"})

    existing = games_table.get_item(Key={"app_id": app_id}).get("Item")
    if not existing:
        return response(404, {"error": "not found"})

    # gnos-games から削除
    games_table.delete_item(Key={"app_id": app_id})

    # gnos-prices の関連レコードを全件削除
    resp = prices_table.query(
        KeyConditionExpression="app_id = :id",
        ExpressionAttributeValues={":id": app_id},
    )
    with prices_table.batch_writer() as batch:
        for item in resp["Items"]:
            batch.delete_item(Key={"app_id": item["app_id"], "checked_at": item["checked_at"]})

    return response(200, {"status": "ok", "deleted": app_id})


def handle_search(params):
    """Steam ストアでゲームを検索して app_id と名前を返す"""
    q = params.get("q", "").strip()
    if not q:
        return response(400, {"error": "q is required"})

    url = (
        "https://store.steampowered.com/api/storesearch/"
        f"?term={urllib.parse.quote(q)}&cc=JP&l=japanese"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    res = urllib.request.urlopen(req, timeout=10)
    data = json.loads(res.read())

    results = [
        {"app_id": str(item["id"]), "name": item["name"]}
        for item in data.get("items", [])
    ]
    return response(200, {"results": results})


def handle_games():
    """全ゲーム一覧を返す（最新価格付き）"""
    items = games_table.scan()["Items"]
    for item in items:
        latest = prices_table.query(
            KeyConditionExpression="app_id = :id",
            ExpressionAttributeValues={":id": item["app_id"]},
            ScanIndexForward=False,
            Limit=1,
        ).get("Items", [])
        if latest:
            item["latest_price"]    = latest[0].get("price", 0)
            item["latest_discount"] = latest[0].get("discount", 0)
    return response(200, {"games": convert_decimals(items)})


def handle_history(params):
    """指定ゲームの価格履歴を返す"""
    app_id = params.get("app_id", "")
    if not app_id:
        return response(400, {"error": "app_id is required"})

    resp = prices_table.query(
        KeyConditionExpression="app_id = :id",
        ExpressionAttributeValues={":id": app_id},
        ScanIndexForward=True,
    )
    return response(200, {
        "app_id": app_id,
        "prices": convert_decimals(resp.get("Items", [])),
    })


def fetch_steam_info(app_id):
    """Steam API からゲーム情報を取得"""
    url = (
        f"https://store.steampowered.com/api/appdetails"
        f"?appids={app_id}&cc=JP&l=japanese"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    res = urllib.request.urlopen(req, timeout=10)
    data = json.loads(res.read())

    app = data.get(str(app_id))
    if not app or not app.get("success"):
        return None

    return app["data"]


def notify(webhook, message):
    """Discord Webhook に通知"""
    payload = json.dumps({"content": message}).encode()
    req = urllib.request.Request(
        webhook,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req)


def convert_decimals(obj):
    """DynamoDB の Decimal を int/float に変換"""
    if isinstance(obj, list):
        return [convert_decimals(i) for i in obj]
    if isinstance(obj, dict):
        return {k: convert_decimals(v) for k, v in obj.items()}
    if isinstance(obj, Decimal):
        return int(obj) if obj == int(obj) else float(obj)
    return obj


def response(status, body):
    """Lambda Function URL 用のレスポンス"""
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _env(key):
    import os
    return os.environ.get(key, "")
