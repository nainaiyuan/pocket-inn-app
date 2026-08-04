#!/bin/bash
# ============================================================
# 🔒 push 前敏感信息安检（8-04 用户要求："不要再把密钥上传上去，
#    以后都要仔细点检测"）
#
# 用法：bash check_secrets.sh [--staged] [--history]
#   --staged   只检查已暂存内容（git hook 用，默认）
#   --history  额外扫全仓库历史（慢，手动用）
#
# 检查项：
#   1. GitHub token 模式（ghp_/github_pat_/gho_/ghs_）
#   2. 常见密钥/密码关键词 + 赋值
#   3. 敏感文件类型被跟踪（.env/.pem/.key/.p12/.jks/凭据）
# 命中任意一项 → 退出码 1，阻止 push
# ============================================================
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 1

MODE="${1:---staged}"
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

# ---- 1. 暂存内容扫描 ----
if [ "$MODE" = "--staged" ] || [ "$MODE" = "--all" ]; then
  echo "🔍 扫描暂存内容..."
  # 只扫新增/修改的文本内容（跳过删除）
  CONTENT=$(git diff --cached --diff-filter=ACMR | grep -vE '^(\+\+\+|---) ' || true)
  HITS=$(echo "$CONTENT" | grep -inE \
    'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}' \
    || true)
  if [ -n "$HITS" ]; then
    echo -e "${RED}✖ 发现 GitHub token 模式！${NC}"
    echo "$HITS" | head -5
    FAIL=1
  fi

  # 密钥关键词（排除常见误报：tokenizer/xxxToken 参数名）
  HITS2=$(echo "$CONTENT" | grep -inE \
    '(api[_-]?key|secret|password|passwd|private[_-]?key)\s*[:=]\s*["'"'"'][A-Za-z0-9_\-]{12,}' \
    || true)
  if [ -n "$HITS2" ]; then
    echo -e "${RED}✖ 发现疑似密钥/密码赋值！${NC}"
    echo "$HITS2" | head -5
    FAIL=1
  fi
fi

# ---- 2. 敏感文件类型 ----
echo "🔍 扫描敏感文件类型..."
SENS=$(git ls-files | grep -iE '\.env$|\.env\.[a-z]+$|\.pem$|\.key$|\.p12$|\.jks$|\.p8$|id_rsa|id_ed25519|credential' || true)
if [ -n "$SENS" ]; then
  echo -e "${RED}✖ 仓库跟踪了敏感文件！${NC}"
  echo "$SENS"
  FAIL=1
fi

# ---- 3. 历史扫描（手动模式）----
if [ "$MODE" = "--history" ]; then
  echo "🔍 扫描全仓库历史（慢）..."
  HIST=$(git log --all -p 2>/dev/null | grep -inE \
    'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}' \
    || true)
  if [ -n "$HIST" ]; then
    echo -e "${RED}✖ 历史提交里有 token！${NC}"
    echo "$HIST" | head -5
    FAIL=1
  fi
fi

if [ "$FAIL" = "1" ]; then
  echo -e "${RED}✖ 安检未通过，已阻止 push。先清理敏感信息再推。${NC}"
  exit 1
fi
echo -e "${GREEN}✅ 安检通过，可以 push。${NC}"
exit 0
