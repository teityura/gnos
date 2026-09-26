import boto3
import json
import os
import urllib.request
from datetime import datetime, timezone

dynamodb = boto3.resource("dynamodb")
games_table = dynamodb.Table("gnos-games")
prices_table = dynamodb.Table("gnos-prices")

# [NOTE] Discord は1通2000文字までなので、変化が多い日は何通かに分けて送る
LIMIT = 2000
HEADER = "📢 **gnos 価格変動のお知らせ**"


def lambda_handler(event, context):
    webhook = os.environ["DISCORD_WEBHOOK"]
    site_url = os.environ["SITE_URL"]
    user_ids = json.loads(os.environ.get("DISCORD_USER_IDS", "{}"))
    now = datetime.now(timezone.utc)

    entries = []
    for game in games_table.scan()["Items"]:
        # [NOTE] アーカイブ済みのゲームは crawler が価格を追い続けるが、通知はしない
        if "latest_price" not in game or game.get("archived_at"):
            continue
        # [NOTE] 通知済みの値がまだ無いゲームは、今の値を基準として覚えるだけにする。導入直後に全ゲーム分が一斉に届くのを防ぐ
        if "notified_price" not in game:
            mark_notified(game)
            continue
        entry = build_entry(game, site_url, user_ids, now)
        if entry:
            entries.append(entry)

    for chunk in split(entries):
        send(webhook, chunk)
        # [NOTE] 送れてから「通知済み」にする。送信に失敗すれば値は変わらず、翌日もう一度送られる
        for entry in chunk:
            if entry["changed"]:
                mark_notified(entry["game"])
            if entry["warned"]:
                mark_warned(entry["game"]["app_id"])

    print(f"通知: {len(entries)} 件")
    return {"statusCode": 200}


def build_entry(game, site_url, user_ids, now):
    """1ゲーム分の通知文を作る。前回通知から変化が無く、セール終了も近くなければ None"""
    app_id = game["app_id"]
    name = game.get("name", app_id)
    cur, cur_disc = game["latest_price"], game.get("latest_discount", 0)
    prev, prev_disc = game["notified_price"], game.get("notified_discount", 0)

    lines = []
    # [NOTE] 通知済みの値と最新値を比べる。crawler が最新値と新しい価格を比べるのと同じ型で、比べる相手が違うだけ
    changed = cur != prev
    if changed:
        lines.append(change_line(name, prev, prev_disc, cur, cur_disc, is_lowest(app_id, cur)))
    warned = sale_ends_soon(game, now)
    if warned:
        lines.append(f"⏰ **{name}** セール終了まで24時間以内 ¥{cur // 100:,} ({cur_disc}%OFF)")
    if not lines:
        return None

    user_id = user_ids.get(game.get("added_by"))
    if user_id:
        lines[0] += f" <@{user_id}>"
    # [NOTE] <> で囲むと Discord がリンクのプレビューを展開しない。まとめ通知でプレビューが並ぶと読めなくなる
    lines.append(f"<https://store.steampowered.com/app/{app_id}/>")
    lines.append(f"履歴 <{site_url}/history.html?app_id={app_id}>")
    return {"text": "\n".join(lines), "user_id": user_id, "game": game, "changed": changed, "warned": warned}


def change_line(name, prev, prev_disc, cur, cur_disc, lowest):
    """前回通知時と今の値から、セール開始・セール終了・価格変動のどれかの1行を作る"""
    price = f"¥{prev // 100:,} → ¥{cur // 100:,}"
    tag = " 🏆 過去最安値" if lowest else ""
    if cur_disc > 0 and prev_disc == 0:
        return f"🎮 **{name}** セール開始 {price} ({cur_disc}%OFF){tag}"
    if cur_disc == 0 and prev_disc > 0:
        return f"📊 **{name}** セール終了 {price}"
    off = f" ({cur_disc}%OFF)" if cur_disc > 0 else ""
    return f"💰 **{name}** 価格変動 {price}{off}{tag}"


def sale_ends_soon(game, now):
    """セール中で、終了まで24時間以内で、まだ警告していなければ True"""
    sale_end_at = game.get("sale_end_at")
    if game.get("latest_discount", 0) == 0 or not sale_end_at or game.get("sale_end_notified"):
        return False
    # [NOTE] notifier は1日1回なので、24時間以内なら終了前に必ず1回は警告できる
    hours_left = (datetime.fromisoformat(sale_end_at) - now).total_seconds() / 3600
    return 0 < hours_left <= 24


def is_lowest(app_id, price):
    """今の価格が履歴の中で最安値（同額を含む）なら True"""
    resp = prices_table.query(
        KeyConditionExpression="app_id = :id",
        ExpressionAttributeValues={":id": app_id},
    )
    prices = [item["price"] for item in resp.get("Items", []) if item.get("price") is not None]
    return bool(prices) and price <= min(prices)


def split(entries):
    """見出しを含めて2000文字に収まるよう、通知文をいくつかの束に分ける"""
    chunks, current, size = [], [], len(HEADER)
    for entry in entries:
        add = len(entry["text"]) + 2
        if current and size + add > LIMIT:
            chunks.append(current)
            current, size = [], len(HEADER)
        current.append(entry)
        size += add
    if current:
        chunks.append(current)
    return chunks


def send(webhook, chunk):
    """1束を Discord に送る。メンションは束の中の登録者だけに絞る"""
    content = "\n\n".join([HEADER] + [entry["text"] for entry in chunk])
    users = sorted({entry["user_id"] for entry in chunk if entry["user_id"]})
    # [NOTE] allowed_mentions で許す相手を明示する。本文に @everyone 等が紛れても鳴らさない
    payload = json.dumps({"content": content, "allowed_mentions": {"parse": [], "users": users}}).encode()
    req = urllib.request.Request(
        webhook,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        },
    )
    urllib.request.urlopen(req)


def mark_notified(game):
    """今の値を「通知済み」として覚える。次回はこの値と比べる"""
    games_table.update_item(
        Key={"app_id": game["app_id"]},
        UpdateExpression="SET notified_price = :p, notified_discount = :d",
        ExpressionAttributeValues={":p": game["latest_price"], ":d": game.get("latest_discount", 0)},
    )


def mark_warned(app_id):
    """セール終了前の警告を出したことを覚え、同じセールで2回出さない"""
    games_table.update_item(
        Key={"app_id": app_id},
        UpdateExpression="SET sale_end_notified = :n",
        ExpressionAttributeValues={":n": True},
    )
