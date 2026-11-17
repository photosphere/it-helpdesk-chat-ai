#!/usr/bin/env bash
# 本地网页接入 Amazon Connect 托管的 communications widget（说明见 README.md 的“网页 widget”一节）
#
# Connect 没有创建 communications widget 的公开 API，widget 需要在 Connect 管理网站中创建一次
# （Channels -> Communications widgets -> Add communications widget），然后把生成的代码片段交给本脚本。
# 本脚本：
#   1. 读取 widget 代码片段（默认 web/widget_snippet.html；交互运行且文件不存在时提示粘贴），解析 widget ID 和脚本地址；
#   2. 检查：片段属于所选实例、启用了 interactive message 类型、实例已启用附件、chat flow 和 Lex bot 已部署；
#   3. 生成 web/index.html（英文 IT Helpdesk 页面，嵌入 widget 片段）并复制测试截图；
#   4. 可选：在 http://localhost:<PORT> 启动本地网页服务并打开浏览器。
#
#   ./setup_widget.sh                       # 交互运行；实例与前缀默认沿用 deploy_chat.sh 保存的 .deploy_settings
#   WIDGET_SNIPPET_FILE=my_snippet.html PORT=8080 SERVE=false ./setup_widget.sh </dev/null
#
# 变量：
#   CONNECT_INSTANCE_ARN / NAME_PREFIX   默认取 .deploy_settings（先运行 deploy_chat.sh）
#   WIDGET_SNIPPET_FILE                  默认 web/widget_snippet.html
#   PORT                                 默认 8080（widget 的允许域名里必须有 http://localhost:<PORT>）
#   PAGE_ORIGINS                         追加到附件桶 CORS 的网站来源，逗号分隔，默认 http://localhost:<PORT>
#                                        （正式网站上线时改成 https://www.example.com 等）
#   SERVE                                交互运行默认询问；true / false
#   COMPANY_NAME                         默认 Example Corp
#   AWS_PROFILE                          可选

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HERE/.deploy_settings"
WEB="$HERE/web"
WIDGET_SNIPPET_FILE="${WIDGET_SNIPPET_FILE:-$WEB/widget_snippet.html}"
PORT="${PORT:-8080}"
SERVE="${SERVE:-}"
COMPANY_NAME="${COMPANY_NAME:-Example Corp}"
ASSUME_YES="${ASSUME_YES:-false}"
WARNINGS=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
interactive() { [[ -t 0 && "$ASSUME_YES" != "true" ]]; }
saved_setting() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  python3 -c "import sys; print(next((l.split('=',1)[1].strip() for l in open(sys.argv[1]) if l.startswith(sys.argv[2]+'=')), ''))" "$SETTINGS_FILE" "$1"
}

ensure_page_cors() {  # $1 bucket。附件文档第 4 步（Option 1）：允许页面所在的网站对附件桶 PUT / GET。只追加缺少的来源，不改已有规则
  local b="$1" origins="${PAGE_ORIGINS:-http://localhost:$PORT}"
  if ! "${AWSC[@]}" s3api get-bucket-cors --bucket "$b" --output json >"$WORK/cors.json" 2>"$WORK/err"; then
    if grep -q "NoSuchCORSConfiguration" "$WORK/err"; then echo '{"CORSRules":[]}' >"$WORK/cors.json"
    else cat "$WORK/err" >&2; warn "无法读取 s3://${b} 的 CORS，未修改；请手工允许 ${origins} 的 PUT / GET"; return 0; fi
  fi
  python3 - "$WORK/cors.json" "$origins" >"$WORK/cors-added.txt" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
rules = c.setdefault("CORSRules", [])
def covered(origin):
    return any(origin in r.get("AllowedOrigins", []) and {"PUT", "GET"} <= set(r.get("AllowedMethods", [])) for r in rules)
missing = [o.strip().rstrip("/") for o in sys.argv[2].split(",") if o.strip() and not covered(o.strip().rstrip("/"))]
if missing:
    rules.append({"AllowedMethods": ["PUT", "GET"], "AllowedOrigins": missing, "AllowedHeaders": ["*"], "MaxAgeSeconds": 3000})
    json.dump({"CORSRules": rules}, open(sys.argv[1], "w"))
print(",".join(missing))
PY
  if [[ -s "$WORK/cors-added.txt" && -n "$(tr -d '\n' <"$WORK/cors-added.txt")" ]]; then
    "${AWSC[@]}" s3api put-bucket-cors --bucket "$b" --cors-configuration "file://$WORK/cors.json"
    log "CORS: allowed PUT / GET from $(tr -d '\n' <"$WORK/cors-added.txt") on s3://${b} (existing rules kept)"
  else
    log "CORS: ${origins} already allowed on s3://${b}"
  fi
}

command -v aws >/dev/null || die "未找到 aws CLI"
command -v python3 >/dev/null || die "未找到 python3"
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "PORT 不合法：$PORT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. 目标实例（沿用 deploy_chat.sh 的选择）
CONNECT_INSTANCE_ARN="${CONNECT_INSTANCE_ARN:-$(saved_setting CONNECT_INSTANCE_ARN)}"
NAME_PREFIX="${NAME_PREFIX:-$(saved_setting NAME_PREFIX)}"
NAME_PREFIX="${NAME_PREFIX:-ith}"
ARN_RE='^arn:aws[a-z-]*:connect:([a-z0-9-]+):([0-9]{12}):instance/([a-f0-9-]+)$'
[[ "${CONNECT_INSTANCE_ARN:-}" =~ $ARN_RE ]] || die "没有找到 Connect 实例：请先运行 ./deploy_chat.sh，或设置 CONNECT_INSTANCE_ARN"
REGION="${BASH_REMATCH[1]}"; INSTANCE_ID="${BASH_REMATCH[3]}"
AWSC=(aws --no-cli-pager --region "$REGION")
if [[ -n "${AWS_PROFILE:-}" ]]; then AWSC+=(--profile "$AWS_PROFILE"); fi
INSTANCE_ALIAS="$("${AWSC[@]}" connect describe-instance --instance-id "$INSTANCE_ID" --query Instance.InstanceAlias --output text)"
UP="$(echo "$NAME_PREFIX" | tr '[:lower:]' '[:upper:]')"
FLOW_NAME="$UP-IT-Helpdesk-Chat"
BOT_NAME="$UP-IT-Helpdesk-Bot"
log "Instance ${INSTANCE_ALIAS} (${INSTANCE_ID}, ${REGION}), flow ${FLOW_NAME}"

# ---------------------------------------------------------------- 2. widget 代码片段
if [[ ! -s "$WIDGET_SNIPPET_FILE" ]]; then
  interactive || die "找不到 widget 代码片段文件 ${WIDGET_SNIPPET_FILE}（设置 WIDGET_SNIPPET_FILE）"
  printf '\n请粘贴 Connect 管理网站中 widget 的完整代码片段（<script> ... </script>），粘贴完后另起一行按 Ctrl-D：\n' >&2
  mkdir -p "$(dirname "$WIDGET_SNIPPET_FILE")"
  cat >"$WIDGET_SNIPPET_FILE" </dev/tty
  [[ -s "$WIDGET_SNIPPET_FILE" ]] || die "没有收到代码片段"
  log "Snippet saved to ${WIDGET_SNIPPET_FILE}"
fi

python3 - "$WIDGET_SNIPPET_FILE" "$INSTANCE_ALIAS" >"$WORK/snippet.env" <<'PY'
import re, sys
snippet, alias = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
def fail(msg):
    print(f"ERROR={msg}"); sys.exit(0)
if "<script" not in snippet or "amazon_connect" not in snippet:
    fail("这不是 Connect communications widget 的代码片段（缺少 <script> 或 amazon_connect）")
src = re.search(r"s\.src\s*=\s*['\"](https://[^'\"]+)['\"]", snippet)
wid = re.search(r"\}\)\(\s*window\s*,\s*document\s*,\s*['\"]amazon_connect['\"]\s*,\s*['\"]([0-9a-f-]{36})['\"]\s*\)", snippet)
snip = re.search(r"amazon_connect\(\s*['\"]snippetId['\"]\s*,\s*['\"]([A-Za-z0-9+/=]+)['\"]", snippet)
if not (src and wid and snip):
    fail("无法从代码片段中解析出脚本地址 / widget ID / snippetId，请粘贴控制台生成的完整片段")
host = re.match(r"https://([^/]+)/", src.group(1)).group(1)
types = re.search(r"supportedMessagingContentTypes['\"]\s*,\s*\[([^\]]*)\]", snippet)
print(f"WIDGET_ID={wid.group(1)}")
print(f"WIDGET_SRC={src.group(1)}")
print(f"WIDGET_HOST={host}")
print(f"HOST_MATCH={'yes' if host.split('.')[0] == alias else 'no'}")
print(f"INTERACTIVE={'yes' if types and 'application/vnd.amazonaws.connect.message.interactive' in types.group(1) else 'no'}")
jwt = re.search(r"amazon_connect\(\s*['\"]authenticate", snippet)
print("JWT=" + ("yes" if jwt else "no"))
PY
snippet_val() { python3 -c "import sys; print(next((l.split('=',1)[1].strip() for l in open(sys.argv[1]) if l.startswith(sys.argv[2]+'=')), ''))" "$WORK/snippet.env" "$1"; }
[[ -z "$(snippet_val ERROR)" ]] || die "$(snippet_val ERROR)"
WIDGET_ID="$(snippet_val WIDGET_ID)"; WIDGET_SRC="$(snippet_val WIDGET_SRC)"; WIDGET_HOST="$(snippet_val WIDGET_HOST)"
log "Widget ${WIDGET_ID} (script ${WIDGET_SRC})"
[[ "$(snippet_val HOST_MATCH)" == yes ]] || die "代码片段来自 ${WIDGET_HOST}，不是所选实例 ${INSTANCE_ALIAS}.my.connect.aws"
if [[ "$(snippet_val INTERACTIVE)" != yes ]]; then
  warn "代码片段的 supportedMessagingContentTypes 不含 application/vnd.amazonaws.connect.message.interactive：ListPicker / Panel 会显示成原始 JSON。请在 widget 设置中启用 interactive messages 后重新复制片段。"
fi
if [[ "$(snippet_val JWT)" == yes ]]; then
  warn "widget 启用了 JWT 安全校验（amazon_connect('authenticate', ...)）：本地页面没有签发 JWT 的服务端，chat 无法开始。测试时请在 widget 设置中关闭 security，或自行实现 /token。"
fi

# ---------------------------------------------------------------- 3. 实例侧检查（只读）
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$WIDGET_SRC" || true)"
[[ "$code" == 200 ]] && log "Widget script reachable (HTTP 200)" || warn "widget 脚本 ${WIDGET_SRC} 返回 HTTP ${code}"

ATTACH_BUCKET="$("${AWSC[@]}" connect list-instance-storage-configs --instance-id "$INSTANCE_ID" --resource-type ATTACHMENTS \
  --query 'StorageConfigs[0].S3Config.BucketName' --output text)"
if [[ -n "$ATTACH_BUCKET" && "$ATTACH_BUCKET" != "None" ]]; then
  log "Attachments enabled on the instance (bucket ${ATTACH_BUCKET})"
  ensure_page_cors "$ATTACH_BUCKET"
else
  warn "实例没有启用附件（Data storage -> Attachments）：widget 不会显示回形针图标。请先运行 ./deploy_chat.sh 或在控制台启用附件。"
fi

"${AWSC[@]}" connect list-contact-flows --instance-id "$INSTANCE_ID" --contact-flow-types CONTACT_FLOW --output json >"$WORK/flows.json"
FLOW_ID="$(python3 -c "import json,sys; print(next((f['Id'] for f in json.load(open(sys.argv[1]))['ContactFlowSummaryList'] if f['Name']==sys.argv[2]), ''))" "$WORK/flows.json" "$FLOW_NAME")"
if [[ -n "$FLOW_ID" ]]; then
  log "Flow ${FLOW_NAME} found (${FLOW_ID})"
else
  warn "实例中没有 flow ${FLOW_NAME}：请先运行 ./deploy_chat.sh（前缀 ${NAME_PREFIX}）。"
fi
if "${AWSC[@]}" connect list-bots --instance-id "$INSTANCE_ID" --lex-version V2 --output json \
    | python3 -c "import json,sys; sys.exit(0 if any(sys.argv[1] in ((b.get('LexV2Bot') or {}).get('AliasArn') or '') for b in json.load(sys.stdin).get('LexBots',[])) else 1)" "bot-alias/"; then
  log "Lex V2 bot associated with the instance"
else
  warn "实例没有关联 Lex V2 bot（${BOT_NAME}）：请先运行 ./deploy_chat.sh。"
fi

# ---------------------------------------------------------------- 4. 生成 web/index.html
mkdir -p "$WEB"
python3 - "$WEB/index.template.html" "$WIDGET_SNIPPET_FILE" "$WEB/index.html" "$COMPANY_NAME" "$INSTANCE_ALIAS" "$WIDGET_ID" <<'PY'
import html, sys
tpl, snippet_file, out, company, alias, wid = sys.argv[1:]
page = open(tpl, encoding="utf-8").read()
snippet = open(snippet_file, encoding="utf-8").read().strip()
for k, v in {"__COMPANY_NAME__": html.escape(company), "__INSTANCE_ALIAS__": html.escape(alias), "__WIDGET_ID__": html.escape(wid)}.items():
    page = page.replace(k, v)
page = page.replace("__WIDGET_SNIPPET__", "  " + snippet.replace("\n", "\n  "))
assert "__" not in page.replace("__proto__", ""), "unrendered placeholder in index.html"
open(out, "w", encoding="utf-8").write(page)
PY
cp "$HERE/samples/wrong_password_screenshot.png" "$WEB/wrong_password_screenshot.png"
log "Generated ${WEB}/index.html (widget ${WIDGET_ID})"

URL="http://localhost:$PORT"
cat <<EOF

========== Widget page ready ==========
  页面    $WEB/index.html
  地址    $URL

在 Connect 管理网站中确认（API 无法读取 widget 设置）：
  https://${INSTANCE_ALIAS}.my.connect.aws -> Channels -> Communications widgets -> 这个 widget -> Edit
  1. Chat 使用的 flow 是 ${FLOW_NAME}。
  2. Allowed domains 中有 ${URL}（协议和端口必须完全一致；用 127.0.0.1 打开页面需要另外添加 http://127.0.0.1:${PORT}）。
  3. 没有启用 security（JWT），否则本地页面无法开始 chat。
  修改保存后，几分钟内生效。

测试：打开页面 -> 右下角按钮 -> Account & sign-in issues -> I can't sign in to the intranet
      -> 用回形针上传页面上的 sample screenshot -> 图片出现后输入 done -> Reset my password -> E10001 / 4821
EOF
[[ $WARNINGS -eq 0 ]] || printf '\n有 %s 个警告，见上方 WARNING。\n' "$WARNINGS"

# ---------------------------------------------------------------- 5. 本地网页服务（前台运行，Ctrl-C 停止）
if [[ -z "$SERVE" ]]; then
  if interactive; then
    read -r -p "现在在 ${URL} 启动本地网页服务并打开浏览器？[Y/n]: " ans </dev/tty || true
    [[ -z "$ans" || "$ans" =~ ^[Yy] ]] && SERVE=true || SERVE=false
  else
    SERVE=false
  fi
fi
if [[ "$SERVE" == "true" ]]; then
  holder="$(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  if [[ -n "$holder" ]]; then
    state="$(ps -o stat= -p "$holder" 2>/dev/null | tr -d ' ' || true)"
    printf '\n端口 %s 被进程 %s 占用：\n  %s\n' "$PORT" "$holder" "$(ps -ww -o command= -p "$holder" 2>/dev/null | cut -c1-200)" >&2
    if [[ "$state" == T* ]]; then
      printf '这个进程处于暂停状态（多半是之前按了 Ctrl-Z），占着端口但不响应请求。\n' >&2
    fi
    printf '释放端口：kill -CONT %s; kill %s（如果是之前的本地网页服务）\n或换端口：PORT=9000 ./setup_widget.sh，并把 http://localhost:9000 加到 widget 的 Allowed domains\n停止本地服务请用 Ctrl-C，不要用 Ctrl-Z。\n' "$holder" "$holder" >&2
    exit 1
  fi
  if command -v open >/dev/null; then (sleep 1; open "$URL") & fi
  log "Serving ${WEB} at ${URL} (Ctrl-C to stop)"
  exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEB"
else
  printf '\n启动本地服务：python3 -m http.server %s --bind 127.0.0.1 --directory %s\n' "$PORT" "$WEB"
fi
