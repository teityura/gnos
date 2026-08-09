#!/bin/sh
# DynamoDB のテーブルを backup/<日時>/ にダンプする。
# 対象は project_name を接頭辞に持つテーブル。
set -eu
cd "$(dirname "$0")"

project=$(terraform -chdir=terraform output -raw project_name)
dest="backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$dest"

aws dynamodb list-tables \
  --query "TableNames[?starts_with(@,'${project}-')]" --output text \
  | tr '\t' '\n' | while read -r t; do
      [ -n "$t" ] || continue
      aws dynamodb scan --table-name "$t" > "$dest/$t.json"
      printf '  %-16s %s items\n' "$t" \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Count"])' "$dest/$t.json")"
    done

ln -sfn "$(basename "$dest")" backup/latest
echo "-> $dest"
