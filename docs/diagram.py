from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.network import APIGateway
from diagrams.aws.storage import S3
from diagrams.aws.integration import Eventbridge
from diagrams.onprem.client import Users
from diagrams.onprem.network import Nginx
from diagrams.saas.chat import Discord
from diagrams.onprem.compute import Server

graph_attr = {
    "fontsize": "15",
    "pad": "1.0",
    "splines": "ortho",
    "nodesep": "0.8",
    "ranksep": "1.2",
}

edge_attr = {
    "penwidth": "2.0",
    "fontsize": "14",
}

with Diagram(
    "gnos — Steam Price Observer",
    filename="diagram",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    edge_attr=edge_attr,
):
    user    = Users("Browser")
    steam   = Server("Steam API")
    discord = Discord("Discord")

    with Cluster("teityura.com  (rproxy)"):
        nginx = Nginx("nginx\nHTTPS")

    with Cluster("AWS"):
        s3      = S3("gnos-site\nS3 Static")
        apigw   = APIGateway("API Gateway")
        gateway = Lambda("gnos-gateway")
        games_db  = Dynamodb("gnos-games")
        prices_db = Dynamodb("gnos-prices")

        with Cluster("Price Monitor  (every 3h)"):
            schedule = Eventbridge("EventBridge")
            observer = Lambda("gnos-observer")

    user_color  = "steelblue"
    event_color = "darkorange"

    def ue(label): return Edge(label=label, color=user_color, fontcolor=user_color, fontsize="18")
    def ee(label, style="solid"): return Edge(label=label, color=event_color, fontcolor=event_color, style=style, fontsize="18")

    # ユーザーフロー（青）
    user >> ue("1. GET page") >> nginx
    nginx >> ue("2. proxy") >> s3
    user >> ue("3. API call (JS direct)") >> apigw
    apigw >> ue("4.") >> gateway
    gateway >> ue("5. R/W") >> games_db
    gateway >> ue("5. R/W") >> prices_db

    # 監視フロー（オレンジ）
    schedule >> ee("1. trigger") >> observer
    observer >> ee("2. get games") >> games_db
    observer >> ee("3. fetch price") >> steam
    observer >> ee("4. save price") >> prices_db
    observer >> ee("5. notify on change", style="dashed") >> discord
