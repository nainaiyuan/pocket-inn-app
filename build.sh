#!/bin/bash
# ============================================================
# 男主APP 编译脚本（用户 8-03 04:36 定下的规矩：下一个停上一个）
# 用法：bash build.sh
# 流程：1) 取消所有排队/运行中的构建 → 2) dispatch 最新 main → 3) 等 workflow 完成
#       → 4) 验证 conclusion=success 且 head_sha=本地 HEAD → 5) 出包
# 出包链接：https://github.com/nainaiyuan/pocket-inn-app/releases/download/latest-apk/app-release.apk
# Token 从 ~/.gh_token 读取（不进 git，8-03 05:1x 泄露事件后改）
# 8-03 18:1x：加"等完成+验证"（之前 dispatch 完就打印 3/3 完成是假信号，
#   workflow 被 cancel 也不知道，出过旧包）
# ============================================================
if [ ! -f ~/.gh_token ]; then
  echo "✖ 找不到 ~/.gh_token，请把 GitHub token 放进去（只有一行）"
  exit 1
fi
TOKEN=$(cat ~/.gh_token | tr -d ' \n')
REPO="nainaiyuan/pocket-inn-app"
WORKFLOW_ID="324715194"
LOCAL_SHA=$(git rev-parse HEAD)

echo "=== 1/4 取消所有 active 构建 ==="
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

echo "=== 2/4 触发新构建（HEAD=$LOCAL_SHA）==="
curl -s -X POST -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_ID/dispatches" \
  -d '{"ref":"main"}' -w "HTTP %{http_code}\n"

echo "=== 3/4 等待构建完成（最多 15 分钟）==="
RUN_ID=""
# 8-03 18:5x：dispatch 后先按 head_sha 找到"本次"的 run（API 有延迟，
#   直接找最新 completed 会撞到旧 run 导致误报 cancelled/失败）
MY_RUN=""
for i in $(seq 1 30); do
  sleep 10
  MY_RUN=$(curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs?per_page=15&event=workflow_dispatch" | \
    python3 -c "
import json,sys
runs=json.load(sys.stdin)['workflow_runs']
for r in runs:
    if r['head_sha'] == '$LOCAL_SHA':
        print(r['id'], r['status']); break
")
  if [ -n "$MY_RUN" ]; then break; fi
done
if [ -z "$MY_RUN" ]; then
  echo "✖ 5 分钟没看到本次 HEAD（$LOCAL_SHA）的 run，放弃"
  exit 1
fi
MY_ID=$(echo $MY_RUN | cut -d' ' -f1)
echo "本次 run：$MY_ID（HEAD=$LOCAL_SHA）"

for i in $(seq 1 60); do
  sleep 10
  ST=$(curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs/$MY_ID" | \
    python3 -c "import json,sys; r=json.load(sys.stdin); print(r['status'], r['conclusion'])")
  S=$(echo $ST | cut -d' ' -f1)
  if [ "$S" = "completed" ]; then
    C=$(echo $ST | cut -d' ' -f2)
    echo "run $MY_ID 完成：$C"
    if [ "$C" != "success" ]; then
      echo "✖ 构建失败或取消（$C）→ 看 https://github.com/$REPO/actions/runs/$MY_ID"
      exit 1
    fi
    RUN_ID=$MY_ID
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then echo "  ...已等 $((i * 10)) 秒"; fi
done
if [ -z "$RUN_ID" ]; then
  echo "✖ 15 分钟没等到构建完成，放弃（看 Actions 页）"
  exit 1
fi

echo "=== 4/4 验证 release 资产 ==="
sleep 20
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/releases/tags/latest-apk" | python3 -c "
import json,sys
r=json.load(sys.stdin)
for a in r.get('assets',[]):
    if a['name']=='app-release.apk':
        print('APK 更新时间：', a['updated_at'])
"
echo "出包链接：https://github.com/nainaiyuan/pocket-inn-app/releases/download/latest-apk/app-release.apk"
