#!/usr/bin/env bash
# 判断本次变更是否涉及需要跑冒烟测试的代码（前后端 / 冒烟用例 / 构建与部署脚本）。
# 用法:
#   app-changes.sh <before-sha> [<after-sha>]    # 基于 git diff 判断（push 场景）
#   app-changes.sh --pr <pr-number>               # 基于 GitHub API 的 PR 文件列表判断
# 输出: true / false；无法判断时保守输出 true（宁可多跑）。
set -euo pipefail

relevant_pattern='^(backend/|frontend/|smoke/|Dockerfile|docker-compose|\.github/scripts/|\.github/workflows/(deploy|deploy-staging|preview))'

if [ "${1:-}" = "--pr" ]; then
  pr_number="${2:?PR number required for --pr mode}"
  repo_full="${REPO_FULL:?REPO_FULL env required for --pr mode}"
  if ! files=$(gh api "repos/${repo_full}/pulls/${pr_number}/files" --paginate --jq '.[].filename' 2>/dev/null); then
    echo true
    exit 0
  fi
  if printf '%s\n' "${files}" | grep -qE "${relevant_pattern}"; then
    echo true
  else
    echo false
  fi
  exit 0
fi

before="${1:-}"
after="${2:-HEAD}"

if [ -z "${before}" ] || [ "${before}" = "0000000000000000000000000000000000000000" ]; then
  echo true
  exit 0
fi

if ! git cat-file -e "${after}^{commit}" 2>/dev/null; then
  echo true
  exit 0
fi

if ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
  git fetch --no-tags --quiet --depth=1 origin "${before}" 2>/dev/null || {
    echo true
    exit 0
  }
fi

if ! changed=$(git diff --name-only "${before}" "${after}" 2>/dev/null); then
  echo true
  exit 0
fi

if printf '%s\n' "${changed}" | grep -qE "${relevant_pattern}"; then
  echo true
else
  echo false
fi
