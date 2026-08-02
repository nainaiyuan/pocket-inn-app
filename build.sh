#!/bin/bash
# ============================================================
# 男主APP 编译脚本（用户 8-03 04:36 定下的规矩：下一个停上一个）
# 用法：bash build.sh
# 流程：1) 取消所有排队/运行中的构建 → 2) dispatch 最新 main → 3) 出包
# 出包链接：https://github.com/nainaiyuan/pocket-inn-app/releases/download/latest-apk/app-release.apk
# Token 从 ~/.gh_token 读取（不进 git，8-03 05:1x 泄露事件后改）
# ============================================================
if [ ! -f ~/.gh_token ]; then
  echo "✖ 找不到 ~/.gh_token，请把 GitHub token 放进去（只有一行）"
  exit 1
fi
TOKEN=$(cat ~/.gh_token | tr -d ' \n')
REPO="nainaiyuan/pocket-inn-app"
WORKFLOW_ID="324715194"

echo "=== 1/3 取消所有 active 构建 ==="
ACTIVE=$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?per_page=100" | \
  python3 -c "import json,sys; [print(r['id']) for r in json.load(sys.stdin)['workflow_runs'] if r['status'] in ('queued','in_progress','waiting','requested')]")
if [ -z "$ACTIVE" ]; then
  echo "没有 active 构建，跳过"
else
  for id in $ACTIVE; do
    echo "取消 run $id ..."
    curl -s -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/actions/runs/$id/cancel" -w "HTTP %{http_code}\n"
  done
  echo "等待取消生效（8秒）..."
  sleep 8
fi

echo "=== 2/3 触发新构建 ==="
curl -s -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_ID/dispatches" \
  -d '{"ref":"main"}' -w "HTTP %{http_code}\n"

echo "=== 3/3 完成 ==="
echo "出包链接：https://github.com/nainaiyuan/pocket-inn-app/releases/download/latest-apk/app-release.apk"
