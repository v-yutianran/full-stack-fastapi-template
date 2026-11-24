#!/usr/bin/env bash
# Coolify PR preview environment helper.
# Modes: up | down | sweep
# Required env: COOLIFY_URL, COOLIFY_TOKEN, COOLIFY_PREVIEW_PROJECT_UUID,
#               COOLIFY_SERVER_UUID, PREVIEW_SECRET_SALT
# up/down also need: ACTION, PR_NUMBER, HEAD_REF, REPO_FULL
set -euo pipefail

API="${COOLIFY_URL%/}/api/v1"
AUTH=(-H "Authorization: Bearer ${COOLIFY_TOKEN}" -H "Content-Type: application/json")

api() { curl -fsS "${AUTH[@]}" "$@"; }
api_code() { curl -sS -o /dev/null -w "%{http_code}" "${AUTH[@]}" "$@"; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

PROJECT="${COOLIFY_PREVIEW_PROJECT_UUID:?}"
SERVER="${COOLIFY_SERVER_UUID:?}"
SALT="${PREVIEW_SECRET_SALT:?}"

find_app() {
  api "$API/applications" | jq -r --arg n "$1" '.[] | select(.name == $n) | .uuid' | head -n1
}

find_db() {
  api "$API/databases" | jq -r --arg n "$1" '.[] | select(.name == $n) | .uuid' | head -n1
}

wait_db() {
  local uuid="$1" i url status
  for i in $(seq 1 48); do
    url=$(api "$API/databases/$uuid" | jq -r '.internal_db_url // empty')
    status=$(api "$API/databases/$uuid" | jq -r '.status // empty')
    if [ -n "$url" ] && [[ "$status" == *healthy* ]]; then
      printf '%s' "$url"
      return 0
    fi
    sleep 5
  done
  echo "database $uuid did not become healthy" >&2
  return 1
}

wait_deployment() {
  local dep="$1" i status
  for i in $(seq 1 90); do
    status=$(api "$API/deployments/$dep" | jq -r '.status // empty')
    case "$status" in
      finished) return 0 ;;
      failed|cancelled*) echo "deployment $dep ended with ${status}" >&2; return 1 ;;
    esac
    sleep 10
  done
  echo "deployment $dep timed out" >&2
  return 1
}

delete_preview() { # app_uuid db_uuid
  local app="$1" db="$2"
  if [ -n "$app" ]; then
    code=$(api_code -X DELETE "$API/applications/$app")
    echo "deleted preview app $app (http $code)"
  fi
  if [ -n "$db" ]; then
    code=$(api_code -X DELETE "$API/databases/$db")
    echo "deleted preview db $db (http $code)"
  fi
}

up() {
  local pr="${PR_NUMBER:?}" ref="${HEAD_REF:?}" repo="${REPO_FULL:?}"
  local name="pr-${pr}" domain="pr-${pr}.preview.yutianran.cn" db_name="preview-db-pr-${pr}"
  local secret_key superuser_password db db_uuid app body envs dep

  secret_key="$(sha "preview-secret-${pr}-${SALT}")"
  superuser_password="Prv-${pr}-$(sha "preview-pw-${pr}-${SALT}" | cut -c1-10)"

  # 1. database
  db=$(find_db "$db_name")
  if [ -z "$db" ]; then
    db=$(api -X POST "$API/databases/postgresql" -d "$(jq -n --arg p "$PROJECT" --arg s "$SERVER" --arg n "$db_name" \
      '{project_uuid:$p,server_uuid:$s,environment_name:"production",name:$n}')" | jq -r '.uuid')
    echo "created preview database $db"
    api -X POST "$API/deploy" -d "$(jq -n --arg u "$db" '{uuid:$u}')" >/dev/null || true
  fi
  db_uuid=$(wait_db "$db")

  # 2. application
  app=$(find_app "$name")
  if [ -z "$app" ]; then
    body=$(jq -n --arg p "$PROJECT" --arg s "$SERVER" --arg repo "https://github.com/${repo}" \
      --arg br "$ref" --arg n "$name" --arg d "https://${domain}" '{
        project_uuid:$p, server_uuid:$s, environment_name:"production",
        git_repository:$repo, git_branch:$br, build_pack:"dockerfile",
        dockerfile_location:"/backend/Dockerfile", base_directory:"/",
        ports_exposes:"8000", name:$n, domains:$d, autogenerate_domain:false,
        instant_deploy:false, is_auto_deploy_enabled:false,
        health_check_enabled:true, health_check_path:"/api/v1/utils/health-check/",
        health_check_port:"8000", health_check_scheme:"http",
        health_check_method:"GET", health_check_return_code:200}')
    app=$(api -X POST "$API/applications/public" -d "$body" | jq -r '.uuid')
    echo "created preview app $app"
  else
    body=$(jq -n --arg br "$ref" --arg d "https://${domain}" '{git_branch:$br,domains:$d}')
    api -X PATCH "$API/applications/$app" -d "$body" >/dev/null
    echo "updated preview app $app"
  fi

  # 3. environment variables
  envs=$(jq -n --arg proj "PR #${pr} Preview" --arg secret "$secret_key" \
    --arg email "admin@yutianran.cn" --arg pass "$superuser_password" --arg dburl "$db_uuid" '{
      data:[
        {key:"PROJECT_NAME",value:$proj},
        {key:"SECRET_KEY",value:$secret},
        {key:"FIRST_SUPERUSER",value:$email},
        {key:"FIRST_SUPERUSER_PASSWORD",value:$pass},
        {key:"DATABASE_URL",value:$dburl},
        {key:"EMAILS_FROM_EMAIL",value:"noreply@yutianran.cn"},
        {key:"SMTP_HOST",value:""},
        {key:"ENVIRONMENT",value:"preview"},
        {key:"SEED_DEMO_DATA",value:"true"}
      ]}')
  api -X PATCH "$API/applications/$app/envs/bulk" -d "$envs" >/dev/null
  api -X PATCH "$API/applications/$app" -d '{"post_deployment_command":"bash scripts/post_start.sh"}' >/dev/null

  # 4. deploy and wait
  dep=$(api -X POST "$API/deploy?uuid=${app}&force=true" -d '{}' | jq -r '.deployments[0].deployment_uuid')
  echo "deployment $dep started"
  wait_deployment "$dep"

  echo "PREVIEW_URL=https://${domain}"
  echo "PREVIEW_USER=admin@yutianran.cn"
  echo "PREVIEW_PASSWORD=${superuser_password}"
}

down() {
  local pr="${PR_NUMBER:?}"
  local app db
  app=$(find_app "pr-${pr}" || true)
  db=$(find_db "preview-db-pr-${pr}" || true)
  if [ -z "$app" ] && [ -z "$db" ]; then
    echo "no preview resources for PR ${pr}"
    return 0
  fi
  delete_preview "$app" "$db"
  local i
  for i in $(seq 1 30); do
    app=$(find_app "pr-${pr}" || true)
    db=$(find_db "preview-db-pr-${pr}" || true)
    if [ -z "$app" ] && [ -z "$db" ]; then
      echo "preview resources for PR ${pr} fully removed"
      return 0
    fi
    sleep 5
  done
  echo "warning: preview resources for PR ${pr} still present" >&2
  return 1
}

sweep() { # delete preview apps/dbs whose PR is no longer open
  local repo="${REPO_FULL:?}" open_numbers app name num db
  if ! open_numbers=$(gh api "repos/${repo}/pulls?state=open&per_page=100" --paginate --jq '.[].number'); then
    echo "could not fetch open PRs; refusing to sweep" >&2
    return 1
  fi
  echo "open PRs: $(echo "${open_numbers}" | tr '\n' ' ')"
  while read -r app name; do
    [ -z "${app}" ] && continue
    num="${name#pr-}"
    if ! printf '%s\n' "${open_numbers}" | grep -qx "${num}"; then
      local orphan_db
      orphan_db=$(find_db "preview-db-pr-${num}" || true)
      echo "removing orphan preview for PR ${num}"
      delete_preview "${app}" "${orphan_db}"
    fi
  done < <(api "$API/applications" | jq -r '.[] | select(.name | test("^pr-[0-9]+$")) | "\(.uuid) \(.name)"')
  # orphan databases without matching app
  while read -r db name; do
    [ -z "${db}" ] && continue
    num="${name#preview-db-pr-}"
    if ! printf '%s\n' "${open_numbers}" | grep -qx "${num}"; then
      echo "removing orphan preview db for PR ${num}"
      code=$(api_code -X DELETE "$API/databases/${db}")
      echo "deleted orphan preview db ${db} (http ${code})"
    fi
  done < <(api "$API/databases" | jq -r '.[] | select(.name | test("^preview-db-pr-[0-9]+$")) | "\(.uuid) \(.name)"')
}

case "${ACTION:?ACTION is required}" in
  up) up ;;
  down) down ;;
  sweep) sweep ;;
  *) echo "unknown ACTION: ${ACTION}" >&2; exit 2 ;;
esac
