#!/usr/bin/env bash
# IT Helpdesk Chat AI - Amazon Connect chat 渠道部署脚本（说明见 README.md）
#
# 场景：员工无法登录公司内网 -> 在 chat 中上传密码错误截图 -> Bedrock 多模态模型分析截图 -> 身份验证 -> 重置密码；
#       其他选项：硬件和外设故障（上传照片分析）、转人工客服。chat 交互全部为英文。
# 交互：Lex V2 bot 的 Lambda 返回 Connect interactive messages（ListPicker 主菜单 / Panel 子菜单）。
#
#   ./deploy_chat.sh       # 中文交互：选择 Connect 实例（输入 ARN 或从列表选）、输入资源前缀（默认 ith），确认后部署
#
#   非交互：CONNECT_INSTANCE_ARN=arn:aws:connect:<region>:<acct>:instance/<id> NAME_PREFIX=ith ASSUME_YES=true \
#           ATTACHMENT_BUCKET_NAME=<仅在实例未配置 ATTACHMENTS 存储时需要> ./deploy_chat.sh </dev/null
#
# 可重复执行：每一步都是“不存在则创建，存在则更新到脚本定义的状态”。
#
# 变量（都有默认值）：
#   CONNECT_INSTANCE_ARN     Connect 实例（交互时可从列表选择；选择保存在 .deploy_settings）
#   NAME_PREFIX              资源前缀，默认 ith（小写字母开头，小写字母/数字，最多 10 位）
#   ASSUME_YES               非交互运行时设为 true
#   AWS_PROFILE              可选
#   ATTACHMENT_BUCKET_NAME   实例还没有 ATTACHMENTS 存储时使用（新建或已有的桶，需与实例同区域）
#   VISION_MODEL_ID          Bedrock 多模态模型，默认按区域选 Claude Sonnet 4.6 推理配置文件（us./eu./global.）
#   TEXT_MODEL_ID            自由文本路由模型，默认同 VISION_MODEL_ID
#   COMPANY_NAME             默认 Example Corp（出现在英文对话中）
#   TRUSTED_DOMAINS          官方登录域名，逗号分隔，默认 intranet.example.com,login.example.com,login.microsoftonline.com
#                            截图里的登录页不在这些域名下 -> 视为疑似钓鱼，转 IT Security 队列
#   HOURS_NAME               新队列使用的营业时间，默认 "Basic Hours"
#   AGENT_USERNAMES          可选，逗号分隔：这些坐席会被改到本方案的路由配置文件（会影响其原有路由）
#   RESEED_DIRECTORY         true 时用 lambda/data/seed_users.json 覆盖模拟员工目录（默认只补缺）
#   SKIP_SMOKE               true 跳过部署后的自检
#   SMOKE_IMAGE              自检用的截图，默认 samples/wrong_password_screenshot.png（设为空跳过截图分析自检）

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$HERE/.deploy_settings"
HOURS_NAME="${HOURS_NAME:-Basic Hours}"
AGENT_USERNAMES="${AGENT_USERNAMES:-}"
COMPANY_NAME="${COMPANY_NAME:-Example Corp}"
TRUSTED_DOMAINS="${TRUSTED_DOMAINS:-intranet.example.com,login.example.com,login.microsoftonline.com}"
RESEED_DIRECTORY="${RESEED_DIRECTORY:-false}"
SKIP_SMOKE="${SKIP_SMOKE:-false}"
SMOKE_IMAGE="${SMOKE_IMAGE-$HERE/samples/wrong_password_screenshot.png}"
ASSUME_YES="${ASSUME_YES:-false}"
LEX_LOCALE="en_US"
LEX_ALIAS_NAME="live"
SMOKE_FAILS=0
SUMMARY=()

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { SUMMARY+=("$*"); }
pyj() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# ---------------------------------------------------------------- interactive settings
interactive() { [[ -t 0 && "$ASSUME_YES" != "true" ]]; }

ask() {  # $1 提示 $2 默认
  local v=""
  if interactive; then read -r -p "$1 [$2]: " v </dev/tty || true; fi
  echo "${v:-$2}"
}

saved_setting() {  # 读取 .deploy_settings（KEY=VALUE，不 source）
  [[ -f "$SETTINGS_FILE" ]] || return 0
  python3 -c "import sys; print(next((l.split('=',1)[1].strip() for l in open(sys.argv[1]) if l.startswith(sys.argv[2]+'=')), ''))" "$SETTINGS_FILE" "$1"
}

ARN_RE='^arn:aws[a-z-]*:connect:([a-z0-9-]+):([0-9]{12}):instance/([a-f0-9-]+)$'

choose_instance() {
  local cur="${CONNECT_INSTANCE_ARN:-$(saved_setting CONNECT_INSTANCE_ARN)}" v region n
  while :; do
    v="$(ask "Connect 实例 ARN（直接回车使用默认；输入 list 从实例列表选择）" "${cur:-list}")"
    if [[ "$v" == "list" ]]; then
      region="$(ask "列出哪个区域的 Connect 实例" "$(aws configure get region 2>/dev/null || echo us-east-1)")"
      aws --no-cli-pager --region "$region" ${AWS_PROFILE:+--profile "$AWS_PROFILE"} connect list-instances --output json >"$WORK/instances.json" \
        || { warn "无法列出 $region 的实例"; continue; }
      n="$(python3 -c "
import json,sys
xs=json.load(open(sys.argv[1])).get('InstanceSummaryList',[])
for i,x in enumerate(xs,1): print(f'  {i:>2}) {x[\"InstanceAlias\"]:<32} {x[\"Id\"]}  {x.get(\"InstanceStatus\",\"\")}', file=sys.stderr)
print(len(xs))" "$WORK/instances.json")"
      [[ "$n" -gt 0 ]] || { warn "$region 没有 Connect 实例"; continue; }
      v="$(ask "请选择序号" "1")"
      [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 && "$v" -le "$n" ]] || { echo "序号无效" >&2; continue; }
      v="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['InstanceSummaryList'][int(sys.argv[2])-1]['Arn'])" "$WORK/instances.json" "$v")"
    fi
    [[ "$v" =~ $ARN_RE ]] && { CONNECT_INSTANCE_ARN="$v"; return; }
    echo "ARN 格式不正确：$v" >&2
  done
}

choose_prefix() {
  local cur="${NAME_PREFIX:-$(saved_setting NAME_PREFIX)}" v
  while :; do
    v="$(ask "资源命名前缀（小写字母开头，小写字母/数字，最多 10 位）" "${cur:-ith}")"
    v="$(echo "$v" | tr '[:upper:]' '[:lower:]')"
    [[ "$v" =~ ^[a-z][a-z0-9]{0,9}$ ]] && { NAME_PREFIX="$v"; return; }
    echo "前缀不合法：$v" >&2
  done
}

derive_names() {
  local up; up="$(echo "$NAME_PREFIX" | tr '[:lower:]' '[:upper:]')"
  PREFIX="$NAME_PREFIX-chat-ai"
  TABLE_NAME="$PREFIX"
  BOT_FN="$PREFIX-bot"
  STREAM_FN="$PREFIX-stream"
  ANALYZE_FN="$PREFIX-analyze"
  ROLE_NAME="$PREFIX-lambda-role"
  LEX_ROLE_NAME="$PREFIX-lex-role"
  TOPIC_NAME="$PREFIX-stream"
  BOT_NAME="$up-IT-Helpdesk-Bot"
  FLOW_NAME="$up-IT-Helpdesk-Chat"
  QUEUE_IT="$up-IT-Helpdesk"
  QUEUE_SECURITY="$up-IT-Security"
  ROUTING_PROFILE_NAME="$up-IT-Helpdesk-Agents"
}

default_model() {  # Claude Sonnet 4.6（多模态）跨区域推理配置文件
  case "$REGION" in
    us-*|ca-*) echo "us.anthropic.claude-sonnet-4-6" ;;
    eu-*) echo "eu.anthropic.claude-sonnet-4-6" ;;
    *) echo "global.anthropic.claude-sonnet-4-6" ;;
  esac
}

init_env() {
  command -v aws >/dev/null || die "未找到 aws CLI"
  command -v python3 >/dev/null || die "未找到 python3"
  WORK="$(mktemp -d)"; trap '_on_exit' EXIT
  if interactive; then
    printf '\n==== 部署目标（IT Helpdesk chat AI）====\n' >&2
    [[ "${CONNECT_INSTANCE_ARN:-}" =~ $ARN_RE ]] || choose_instance
    [[ -n "${NAME_PREFIX:-}" ]] || choose_prefix
  else
    CONNECT_INSTANCE_ARN="${CONNECT_INSTANCE_ARN:-$(saved_setting CONNECT_INSTANCE_ARN)}"
    NAME_PREFIX="${NAME_PREFIX:-$(saved_setting NAME_PREFIX)}"
    NAME_PREFIX="${NAME_PREFIX:-ith}"
  fi
  NAME_PREFIX="$(echo "$NAME_PREFIX" | tr '[:upper:]' '[:lower:]')"
  [[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9]{0,9}$ ]] || die "NAME_PREFIX 不合法：$NAME_PREFIX"
  [[ "${CONNECT_INSTANCE_ARN:-}" =~ $ARN_RE ]] \
    || die "请设置 CONNECT_INSTANCE_ARN=arn:aws:connect:<region>:<account>:instance/<id>（或在终端中运行以交互选择）"
  REGION="${BASH_REMATCH[1]}"; ACCOUNT="${BASH_REMATCH[2]}"; INSTANCE_ID="${BASH_REMATCH[3]}"
  PARTITION="$(echo "$CONNECT_INSTANCE_ARN" | cut -d: -f2)"
  AWSC=(aws --no-cli-pager --region "$REGION")
  if [[ -n "${AWS_PROFILE:-}" ]]; then AWSC+=(--profile "$AWS_PROFILE"); fi
  local caller; caller="$("${AWSC[@]}" sts get-caller-identity --query Account --output text)"
  [[ "$caller" == "$ACCOUNT" ]] || die "当前凭证属于账号 ${caller}，实例在账号 $ACCOUNT"
  INSTANCE_ALIAS="$("${AWSC[@]}" connect describe-instance --instance-id "$INSTANCE_ID" --query Instance.InstanceAlias --output text)"
  VISION_MODEL_ID="${VISION_MODEL_ID:-$(default_model)}"
  TEXT_MODEL_ID="${TEXT_MODEL_ID:-$VISION_MODEL_ID}"
  derive_names
  if interactive; then
    printf '\n  实例         %s（%s，%s，账号 %s）\n  前缀         %s\n  Lambda       %s / %s / %s\n  DynamoDB     %s\n  SNS          %s\n  Lex bot      %s（别名 %s，%s）\n  flow         %s\n  队列         %s / %s\n  路由配置文件 %s\n  多模态模型   %s\n\n' \
      "$INSTANCE_ALIAS" "$INSTANCE_ID" "$REGION" "$ACCOUNT" "$NAME_PREFIX" "$BOT_FN" "$STREAM_FN" "$ANALYZE_FN" "$TABLE_NAME" "$TOPIC_NAME" \
      "$BOT_NAME" "$LEX_ALIAS_NAME" "$LEX_LOCALE" "$FLOW_NAME" "$QUEUE_IT" "$QUEUE_SECURITY" "$ROUTING_PROFILE_NAME" "$VISION_MODEL_ID" >&2
    local ok; read -r -p "确认部署到以上实例并使用以上名称？[Y/n]: " ok </dev/tty || true
    [[ -z "$ok" || "$ok" =~ ^[Yy] ]] || die "已取消。"
  fi
  printf 'NAME_PREFIX=%s\nCONNECT_INSTANCE_ARN=%s\n' "$NAME_PREFIX" "$CONNECT_INSTANCE_ARN" >"$SETTINGS_FILE"
  log "Instance $INSTANCE_ALIAS ($INSTANCE_ID) in $REGION, prefix $NAME_PREFIX, model $VISION_MODEL_ID"
}

unique_id() {  # $1 json file $2 list key $3 name field $4 name $5 id field -> id（不存在为空，重名则退出）
  python3 - "$@" <<'PY'
import json, sys
f, key, field, name, idf = sys.argv[1:]
m = [x for x in json.load(open(f)).get(key, []) if x.get(field) == name]
if len(m) > 1:
    sys.exit(f"ERROR: {len(m)} resources named '{name}' in {key} - rename or delete the duplicates, the script will not guess.")
print(m[0][idf] if m else "")
PY
}

# ---------------------------------------------------------------- 1. chat attachments storage
ensure_bucket() {  # $1 bucket：不存在则创建私有、加密的桶
  local b="$1"
  if "${AWSC[@]}" s3api head-bucket --bucket "$b" --expected-bucket-owner "$ACCOUNT" >/dev/null 2>"$WORK/err"; then return 0; fi
  grep -qE "404|Not Found" "$WORK/err" || { cat "$WORK/err" >&2; die "桶 $b 已存在但账号 $ACCOUNT 无法访问"; }
  log "Creating S3 bucket $b"
  if [[ "$REGION" == "us-east-1" ]]; then "${AWSC[@]}" s3api create-bucket --bucket "$b" >/dev/null
  else "${AWSC[@]}" s3api create-bucket --bucket "$b" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
  "${AWSC[@]}" s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  "${AWSC[@]}" s3api put-bucket-encryption --bucket "$b" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

ensure_attachment_storage() {  # 客户在 chat 中上传的文件保存在实例的 ATTACHMENTS 存储里，bot 从这里读截图
  "${AWSC[@]}" connect list-instance-storage-configs --instance-id "$INSTANCE_ID" --resource-type ATTACHMENTS --output json >"$WORK/att.json"
  if [[ "$(pyj 'len(d.get("StorageConfigs",[]))' <"$WORK/att.json")" -eq 0 ]]; then
    [[ -n "${ATTACHMENT_BUCKET_NAME:-}" ]] || die "实例未启用附件（ATTACHMENTS 存储）。请设置 ATTACHMENT_BUCKET_NAME=<$REGION 的新桶或已有桶> 后重试。"
    ensure_bucket "$ATTACHMENT_BUCKET_NAME"
    python3 -c "import json,sys; print(json.dumps({'StorageType':'S3','S3Config':{'BucketName':sys.argv[1],'BucketPrefix':sys.argv[2]}}))" \
      "$ATTACHMENT_BUCKET_NAME" "connect/$INSTANCE_ALIAS/Attachments" >"$WORK/storage.json"
    "${AWSC[@]}" connect associate-instance-storage-config --instance-id "$INSTANCE_ID" --resource-type ATTACHMENTS \
      --storage-config "file://$WORK/storage.json" >/dev/null
    "${AWSC[@]}" connect list-instance-storage-configs --instance-id "$INSTANCE_ID" --resource-type ATTACHMENTS --output json >"$WORK/att.json"
    note "ATTACHMENTS storage: associated s3://$ATTACHMENT_BUCKET_NAME/connect/$INSTANCE_ALIAS/Attachments"
  fi
  ATTACH_BUCKET="$(pyj 'd["StorageConfigs"][0]["S3Config"]["BucketName"]' <"$WORK/att.json")"
  ATTACH_PREFIX="$(pyj 'd["StorageConfigs"][0]["S3Config"].get("BucketPrefix","").strip("/")' <"$WORK/att.json")"
  ATTACH_KMS="$(pyj '(d["StorageConfigs"][0]["S3Config"].get("EncryptionConfig") or {}).get("KeyId","")' <"$WORK/att.json")"
  note "Chat attachments read from s3://$ATTACH_BUCKET/${ATTACH_PREFIX:+$ATTACH_PREFIX/}chat/${ATTACH_KMS:+ (KMS $ATTACH_KMS)}"
  # 坐席在 Agent Workspace 打开附件需要 CORS：只追加缺少的规则，不覆盖已有配置
  local origin="https://$INSTANCE_ALIAS.my.connect.aws"
  if ! "${AWSC[@]}" s3api get-bucket-cors --bucket "$ATTACH_BUCKET" --output json >"$WORK/cors.json" 2>"$WORK/err"; then
    if grep -q "NoSuchCORSConfiguration" "$WORK/err"; then echo '{"CORSRules":[]}' >"$WORK/cors.json"
    else cat "$WORK/err" >&2; warn "无法读取 s3://$ATTACH_BUCKET 的 CORS，未修改"; return 0; fi
  fi
  if python3 - "$WORK/cors.json" "$origin" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); o = sys.argv[2]
if any(o in r.get("AllowedOrigins", []) for r in c.get("CORSRules", [])):
    sys.exit(1)
c.setdefault("CORSRules", []).append({"AllowedMethods": ["PUT", "GET"], "AllowedOrigins": [o], "AllowedHeaders": ["*"], "MaxAgeSeconds": 3000})
json.dump({"CORSRules": c["CORSRules"]}, open(sys.argv[1], "w"))
PY
  then
    "${AWSC[@]}" s3api put-bucket-cors --bucket "$ATTACH_BUCKET" --cors-configuration "file://$WORK/cors.json"
    note "CORS: added $origin to s3://$ATTACH_BUCKET"
  fi
}

ensure_chat_attachment_types() {  # 文档第 3 步：CHAT 渠道允许的文件类型。只补缺少的截图类型，不删除已有类型，不改大小上限
  local need="png,jpg,jpeg" min_bytes=4194304
  if ! "${AWSC[@]}" connect describe-attached-files-configuration --instance-id "$INSTANCE_ID" --attachment-scope CHAT \
      --output json >"$WORK/chat-files.json" 2>"$WORK/err"; then
    cat "$WORK/err" >&2
    warn "无法读取 CHAT 渠道的附件文件类型配置，未修改。请在管理网站 Settings -> Attachments -> Chat 中确认允许 png / jpg / jpeg。"
    note "WARNING: CHAT attachment file types not verified"
    return 0
  fi
  python3 - "$WORK/chat-files.json" "$need" "$min_bytes" >"$WORK/chat-files.env" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["AttachedFilesConfiguration"]
need, min_bytes = sys.argv[2].split(","), int(sys.argv[3])
have = [e["Extension"] for e in (c.get("ExtensionConfiguration") or {}).get("AllowedExtensions", [])]
missing = [e for e in need if e not in {h.lower() for h in have}]
size = int(c.get("MaximumSizeLimitInBytes") or 0)
print("MISSING=" + ",".join(missing))
print("SIZE=" + str(size))
print("SIZE_OK=" + ("yes" if size >= min_bytes else "no"))
json.dump({"AllowedExtensions": [{"Extension": e} for e in have + missing]}, open(sys.argv[1] + ".new", "w"))
PY
  local missing size
  missing="$(python3 -c "import sys; print(next((l.split('=',1)[1].strip() for l in open(sys.argv[1]) if l.startswith('MISSING=')), ''))" "$WORK/chat-files.env")"
  size="$(python3 -c "import sys; print(next((l.split('=',1)[1].strip() for l in open(sys.argv[1]) if l.startswith('SIZE=')), '0'))" "$WORK/chat-files.env")"
  if [[ -n "$missing" ]]; then
    log "Adding chat attachment file types: $missing"
    "${AWSC[@]}" connect update-attached-files-configuration --instance-id "$INSTANCE_ID" --attachment-scope CHAT \
      --maximum-size-limit-in-bytes "$size" --extension-configuration "file://$WORK/chat-files.json.new" >/dev/null
    note "Chat attachment file types: added $missing (existing types kept, size limit unchanged)"
  else
    note "Chat attachment file types: png / jpg / jpeg allowed, max $((size / 1048576)) MB"
  fi
  if grep -q '^SIZE_OK=no' "$WORK/chat-files.env"; then
    warn "CHAT 渠道附件大小上限只有 $((size / 1024)) KB，较大的截图会被拒绝。建议在 Settings -> Attachments -> Chat 中调到 4 MB 以上（脚本不修改大小上限）。"
    note "WARNING: chat attachment size limit $((size / 1024)) KB is below 4 MB"
  fi
}

# ---------------------------------------------------------------- 2. DynamoDB（模拟员工目录 + 附件索引 + 重置记录）
ensure_table() {
  if ! "${AWSC[@]}" dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
    log "Creating DynamoDB table $TABLE_NAME"
    "${AWSC[@]}" dynamodb create-table --table-name "$TABLE_NAME" \
      --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
      --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST --sse-specification Enabled=true --tags Key=Project,Value=it-helpdesk-chat-ai >/dev/null
  fi
  "${AWSC[@]}" dynamodb wait table-exists --table-name "$TABLE_NAME"
  if [[ "$("${AWSC[@]}" dynamodb describe-time-to-live --table-name "$TABLE_NAME" --query TimeToLiveDescription.TimeToLiveStatus --output text)" != "ENABLED" ]]; then
    "${AWSC[@]}" dynamodb update-time-to-live --table-name "$TABLE_NAME" --time-to-live-specification Enabled=true,AttributeName=ttl >/dev/null
  fi
  TABLE_ARN="$("${AWSC[@]}" dynamodb describe-table --table-name "$TABLE_NAME" --query Table.TableArn --output text)"
}

seed_directory() {  # $1 force(true/false)：模拟员工目录 USER#<employee_id>/PROFILE
  local force="${1:-$RESEED_DIRECTORY}" n=0 item emp
  # 先把条目写到文件再逐行读取（bash 3.2 无法正确解析进程替换里的 heredoc）
  python3 - "$HERE/lambda/data/seed_users.json" >"$WORK/seed-items.jsonl" <<'PY'
import json, sys
def av(v):
    if isinstance(v, bool): return {"BOOL": v}
    if isinstance(v, (int, float)): return {"N": str(v)}
    return {"S": str(v)}
for u in json.load(open(sys.argv[1]))["users"]:
    item = {"pk": {"S": "USER#" + u["employee_id"]}, "sk": {"S": "PROFILE"}}
    item.update({k: av(v) for k, v in u.items()})
    print(json.dumps(item))
PY
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    emp="$(echo "$item" | pyj 'd["pk"]["S"]')"
    if [[ "$force" == "true" ]]; then
      "${AWSC[@]}" dynamodb put-item --table-name "$TABLE_NAME" --item "$item"
      n=$((n + 1))
    elif "${AWSC[@]}" dynamodb put-item --table-name "$TABLE_NAME" --item "$item" \
        --condition-expression "attribute_not_exists(pk)" 2>"$WORK/err"; then
      n=$((n + 1))
    else
      grep -q ConditionalCheckFailed "$WORK/err" || { cat "$WORK/err" >&2; die "写入 $emp 失败"; }
    fi
  done <"$WORK/seed-items.jsonl"
  [[ -s "$WORK/seed-items.jsonl" ]] || die "lambda/data/seed_users.json 没有生成任何员工记录"
  if [[ "$force" == "true" || $n -gt 0 ]]; then note "Mock directory: $n employee record(s) written from lambda/data/seed_users.json"; fi
  return 0
}

# ---------------------------------------------------------------- 3. SNS topic（chat 消息流）
ensure_topic() {
  TOPIC_ARN="$("${AWSC[@]}" sns create-topic --name "$TOPIC_NAME" --tags Key=Project,Value=it-helpdesk-chat-ai --query TopicArn --output text)"
  python3 - "$TOPIC_ARN" "$ACCOUNT" "$CONNECT_INSTANCE_ARN" >"$WORK/topic-policy.json" <<'PY'
import json, sys
topic, acct, inst = sys.argv[1:]
print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Sid": "Owner", "Effect": "Allow", "Principal": {"AWS": f"arn:aws:iam::{acct}:root"},
     "Action": ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:ListSubscriptionsByTopic"], "Resource": topic},
    {"Sid": "ConnectChatStreaming", "Effect": "Allow", "Principal": {"Service": "connect.amazonaws.com"}, "Action": "sns:Publish", "Resource": topic,
     "Condition": {"StringEquals": {"aws:SourceAccount": acct}, "ArnEquals": {"aws:SourceArn": inst}}}]}))
PY
  "${AWSC[@]}" sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name Policy --attribute-value "file://$WORK/topic-policy.json"
  note "SNS topic $TOPIC_ARN (chat message streaming, publish allowed for this Connect instance only)"
}

# ---------------------------------------------------------------- 4. IAM
ensure_role() {  # $1 role name $2 trust service $3 policy file $4 description
  python3 -c "import json,sys; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':sys.argv[1]},'Action':'sts:AssumeRole'}]}))" "$2" >"$WORK/trust.json"
  if ! "${AWSC[@]}" iam get-role --role-name "$1" >/dev/null 2>&1; then
    log "Creating IAM role $1"
    "${AWSC[@]}" iam create-role --role-name "$1" --assume-role-policy-document "file://$WORK/trust.json" --description "$4" >/dev/null
    sleep 10  # IAM 传播
  fi
  "${AWSC[@]}" iam update-assume-role-policy --role-name "$1" --policy-document "file://$WORK/trust.json"
  "${AWSC[@]}" iam put-role-policy --role-name "$1" --policy-name "$1-policy" --policy-document "file://$3"
}

ensure_roles() {
  python3 - "$CONNECT_INSTANCE_ARN" "$TABLE_ARN" "$REGION" "$ACCOUNT" "$ATTACH_BUCKET" "$ATTACH_PREFIX" "$ATTACH_KMS" "$PARTITION" >"$WORK/lambda-policy.json" <<'PY'
import json, sys
inst, table, region, acct, bucket, prefix, kms, part = sys.argv[1:]
chat = (prefix + "/" if prefix else "") + "chat/"
st = [
    {"Sid": "Logs", "Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": f"arn:{part}:logs:{region}:{acct}:*"},
    {"Sid": "Table", "Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query", "dynamodb:DeleteItem"], "Resource": table},
    {"Sid": "Connect", "Effect": "Allow", "Action": ["connect:StartContactStreaming", "connect:UpdateContactAttributes"], "Resource": [inst, inst + "/*"]},
    {"Sid": "Bedrock", "Effect": "Allow", "Action": ["bedrock:InvokeModel"],
     "Resource": [f"arn:{part}:bedrock:*::foundation-model/anthropic.*", f"arn:{part}:bedrock:::foundation-model/anthropic.*",
                  f"arn:{part}:bedrock:*:{acct}:inference-profile/*"]},
    {"Sid": "ChatAttachmentsList", "Effect": "Allow", "Action": "s3:ListBucket", "Resource": f"arn:{part}:s3:::{bucket}",
     "Condition": {"StringLike": {"s3:prefix": [chat + "*"]}}},
    {"Sid": "ChatAttachmentsRead", "Effect": "Allow", "Action": "s3:GetObject", "Resource": f"arn:{part}:s3:::{bucket}/{chat}*"},
]
if kms:
    key = kms if kms.startswith("arn:") else f"arn:{part}:kms:{region}:{acct}:key/{kms}"
    st.append({"Sid": "ChatAttachmentsKms", "Effect": "Allow", "Action": "kms:Decrypt", "Resource": key})
print(json.dumps({"Version": "2012-10-17", "Statement": st}))
PY
  ensure_role "$ROLE_NAME" lambda.amazonaws.com "$WORK/lambda-policy.json" "IT Helpdesk chat AI Lambdas"
  LAMBDA_ROLE_ARN="$("${AWSC[@]}" iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
  echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"polly:SynthesizeSpeech","Resource":"*"}]}' >"$WORK/lex-policy.json"
  ensure_role "$LEX_ROLE_NAME" lexv2.amazonaws.com "$WORK/lex-policy.json" "IT Helpdesk chat Lex V2 bot"
  LEX_ROLE_ARN="$("${AWSC[@]}" iam get-role --role-name "$LEX_ROLE_NAME" --query Role.Arn --output text)"
}

# ---------------------------------------------------------------- 5. Lambda
build_package() {  # 确定性 zip：代码不变则 CodeSha256 不变，不会重复上传
  python3 - "$HERE/lambda" "$WORK/lambda.zip" <<'PY'
import pathlib, sys, zipfile
src, dst = pathlib.Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(src.rglob("*")):
        if p.is_file() and "__pycache__" not in p.parts and p.suffix in (".py", ".json"):
            info = zipfile.ZipInfo(p.relative_to(src).as_posix(), (1980, 1, 1, 0, 0, 0))
            info.compress_type, info.create_system, info.external_attr = zipfile.ZIP_DEFLATED, 3, 0o100644 << 16
            z.writestr(info, p.read_bytes())
PY
  CODE_SHA="$(python3 -c "import base64,hashlib,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],'rb').read()).digest()).decode())" "$WORK/lambda.zip")"
  python3 - "$WORK/env.json" TABLE_NAME "$TABLE_NAME" INSTANCE_ID "$INSTANCE_ID" STREAM_TOPIC_ARN "$TOPIC_ARN" \
    ATTACHMENTS_BUCKET "$ATTACH_BUCKET" ATTACHMENTS_PREFIX "$ATTACH_PREFIX" VISION_MODEL_ID "$VISION_MODEL_ID" \
    TEXT_MODEL_ID "$TEXT_MODEL_ID" COMPANY_NAME "$COMPANY_NAME" TRUSTED_DOMAINS "$TRUSTED_DOMAINS" <<'PY'
import json, sys
a = sys.argv[2:]
json.dump({"Variables": {k: v for k, v in zip(a[0::2], a[1::2]) if v}}, open(sys.argv[1], "w"))
PY
}

deploy_fn() {  # $1 name $2 handler $3 timeout $4 memory
  local name="$1" handler="$2" timeout="$3" memory="$4" i
  if "${AWSC[@]}" lambda get-function-configuration --function-name "$name" --output json >"$WORK/fn.json" 2>"$WORK/err"; then
    if [[ "$(pyj 'd.get("CodeSha256","")' <"$WORK/fn.json")" != "$CODE_SHA" ]]; then
      log "Updating code of Lambda $name"
      "${AWSC[@]}" lambda update-function-code --function-name "$name" --zip-file "fileb://$WORK/lambda.zip" >/dev/null
      "${AWSC[@]}" lambda wait function-updated --function-name "$name"
    fi
    "${AWSC[@]}" lambda update-function-configuration --function-name "$name" --handler "$handler" --runtime python3.12 \
      --role "$LAMBDA_ROLE_ARN" --timeout "$timeout" --memory-size "$memory" --environment "file://$WORK/env.json" >/dev/null
  elif grep -q "ResourceNotFoundException" "$WORK/err"; then
    log "Creating Lambda $name"
    for i in 1 2 3 4 5; do
      if "${AWSC[@]}" lambda create-function --function-name "$name" --runtime python3.12 --handler "$handler" \
          --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$WORK/lambda.zip" --timeout "$timeout" --memory-size "$memory" \
          --environment "file://$WORK/env.json" --tags Project=it-helpdesk-chat-ai >/dev/null 2>"$WORK/err"; then
        break
      fi
      if grep -q "cannot be assumed" "$WORK/err" && [[ $i -lt 5 ]]; then sleep $((i * 3)); continue; fi
      cat "$WORK/err" >&2; die "create-function $name 失败"
    done
  else
    cat "$WORK/err" >&2; die "无法读取 Lambda $name"
  fi
  "${AWSC[@]}" lambda wait function-updated --function-name "$name"
}

add_permission_once() {  # $1 function $2 sid $3 principal $4 source arn
  local pol
  pol="$("${AWSC[@]}" lambda get-policy --function-name "$1" --query Policy --output text 2>/dev/null || echo '{}')"
  if ! python3 -c "import json,sys; p=json.loads(sys.argv[1] if sys.argv[1] not in ('','None') else '{}'); sys.exit(0 if any(s.get('Sid')==sys.argv[2] for s in p.get('Statement',[])) else 1)" "$pol" "$2"; then
    "${AWSC[@]}" lambda add-permission --function-name "$1" --statement-id "$2" --action lambda:InvokeFunction \
      --principal "$3" --source-account "$ACCOUNT" --source-arn "$4" >/dev/null
  fi
}

deploy_lambdas() {
  build_package
  deploy_fn "$BOT_FN" bot.lambda_handler 30 512
  deploy_fn "$STREAM_FN" stream.lambda_handler 10 256
  # analyze：flow 以 Asynchronous 模式调用（Connect 最长等 60 秒），读截图并调用 Bedrock
  deploy_fn "$ANALYZE_FN" analyze.lambda_handler 55 512
  BOT_FN_ARN="$("${AWSC[@]}" lambda get-function --function-name "$BOT_FN" --query Configuration.FunctionArn --output text)"
  STREAM_FN_ARN="$("${AWSC[@]}" lambda get-function --function-name "$STREAM_FN" --query Configuration.FunctionArn --output text)"
  ANALYZE_FN_ARN="$("${AWSC[@]}" lambda get-function --function-name "$ANALYZE_FN" --query Configuration.FunctionArn --output text)"
  # stream：由 Connect flow 调用（StartContactStreaming），并订阅 SNS（记录客户上传的附件）
  add_permission_once "$STREAM_FN" "connect-${INSTANCE_ID:0:8}" connect.amazonaws.com "$CONNECT_INSTANCE_ARN"
  add_permission_once "$STREAM_FN" "sns-stream" sns.amazonaws.com "$TOPIC_ARN"
  add_permission_once "$ANALYZE_FN" "connect-${INSTANCE_ID:0:8}" connect.amazonaws.com "$CONNECT_INSTANCE_ARN"
  local fn_arn
  for fn_arn in "$STREAM_FN_ARN" "$ANALYZE_FN_ARN"; do
    if ! "${AWSC[@]}" connect list-lambda-functions --instance-id "$INSTANCE_ID" --output json \
        | python3 -c "import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin).get('LambdaFunctions',[]) else 1)" "$fn_arn"; then
      "${AWSC[@]}" connect associate-lambda-function --instance-id "$INSTANCE_ID" --function-arn "$fn_arn"
    fi
  done
  echo '{"ParticipantRole":["CUSTOMER"]}' >"$WORK/filter.json"
  local sub
  sub="$("${AWSC[@]}" sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json \
    | python3 -c "import json,sys; print(next((s['SubscriptionArn'] for s in json.load(sys.stdin).get('Subscriptions',[]) if s.get('Endpoint')==sys.argv[1] and s['SubscriptionArn'].startswith('arn:')), ''))" "$STREAM_FN_ARN")"
  if [[ -z "$sub" ]]; then
    "${AWSC[@]}" sns subscribe --topic-arn "$TOPIC_ARN" --protocol lambda --notification-endpoint "$STREAM_FN_ARN" \
      --attributes "{\"FilterPolicy\":$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read().strip()))' "$WORK/filter.json")}" >/dev/null
  else
    "${AWSC[@]}" sns set-subscription-attributes --subscription-arn "$sub" --attribute-name FilterPolicy --attribute-value "file://$WORK/filter.json"
  fi
  note "Lambdas: $BOT_FN (Lex code hook) + $ANALYZE_FN (async image analysis, $VISION_MODEL_ID) + $STREAM_FN (streaming start + SNS attachment recorder)"
}

# ---------------------------------------------------------------- 6. Lex V2 bot（interactive messages 由 bot Lambda 返回）
lex() { "${AWSC[@]}" lexv2-models "$@"; }

lex_list_all() {  # $1 输出文件 $2 列表字段 $3.. lexv2-models 子命令和参数
  # Lex V2 的 List* 不会被 CLI 自动翻页（带过滤条件时首页可能为空但带 nextToken），这里手动翻页
  local out="$1" key="$2" token="" page=0
  shift 2
  python3 -c "import json,sys; json.dump({sys.argv[2]: []}, open(sys.argv[1], 'w'))" "$out" "$key"
  while :; do
    page=$((page + 1))
    if [[ -n "$token" ]]; then lex "$@" --max-results 100 --next-token "$token" --output json >"$WORK/lex-page.json"
    else lex "$@" --max-results 100 --output json >"$WORK/lex-page.json"; fi
    token="$(python3 -c "
import json, sys
acc, page = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
acc[sys.argv[3]] += page.get(sys.argv[3], [])
json.dump(acc, open(sys.argv[1], 'w'))
print(page.get('nextToken') or '')" "$out" "$WORK/lex-page.json" "$key")"
    [[ -n "$token" && $page -lt 50 ]] || break
  done
}

lex_list_bots() {  # -> $WORK/bots.json
  lex_list_all "$WORK/bots.json" botSummaries list-bots --filters "name=BotName,values=$BOT_NAME,operator=EQ"
}

ensure_bot() {
  local def_hash alias_id cur_desc cur_ver new_ver intent_id
  lex_list_bots
  BOT_ID="$(unique_id "$WORK/bots.json" botSummaries botName "$BOT_NAME" botId)"
  if [[ -z "$BOT_ID" ]]; then
    log "Creating Lex V2 bot $BOT_NAME"
    BOT_ID="$(lex create-bot --bot-name "$BOT_NAME" --role-arn "$LEX_ROLE_ARN" --data-privacy childDirected=false \
      --idle-session-ttl-in-seconds 900 --description "IT Helpdesk chat assistant (interactive messages via Lambda)" \
      --bot-tags Project=it-helpdesk-chat-ai --query botId --output text)"
  fi
  lex wait bot-available --bot-id "$BOT_ID"
  BOT_ARN="arn:$PARTITION:lex:$REGION:$ACCOUNT:bot/$BOT_ID"

  # 定义哈希（意图文件 + code hook Lambda）：没变化时不重新 build / 发布版本
  def_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read() + " ".join(sys.argv[2:]).encode()).hexdigest()[:16])' \
    "$HERE/lex/helpdesk_intent.json" "$BOT_FN_ARN" "$LEX_LOCALE" v1)"
  lex_list_all "$WORK/aliases.json" botAliasSummaries list-bot-aliases --bot-id "$BOT_ID"
  alias_id="$(unique_id "$WORK/aliases.json" botAliasSummaries botAliasName "$LEX_ALIAS_NAME" botAliasId)"
  cur_desc=""; cur_ver=""
  if [[ -n "$alias_id" ]]; then
    lex describe-bot-alias --bot-id "$BOT_ID" --bot-alias-id "$alias_id" --output json >"$WORK/alias.json"
    cur_desc="$(pyj 'd.get("description","")' <"$WORK/alias.json")"
    cur_ver="$(pyj 'd.get("botVersion","")' <"$WORK/alias.json")"
  fi

  if [[ "$cur_desc" == "def=$def_hash" && "$cur_ver" =~ ^[0-9]+$ ]]; then
    log "Lex bot $BOT_NAME unchanged (version $cur_ver)"
    new_ver="$cur_ver"
  else
    if ! lex describe-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" >/dev/null 2>&1; then
      log "Creating Lex locale $LEX_LOCALE"
      lex create-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" \
        --nlu-intent-confidence-threshold 0.40 >/dev/null
      lex wait bot-locale-created --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE"
    fi
    python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['sampleUtterances']))" "$HERE/lex/helpdesk_intent.json" >"$WORK/utterances.json"
    lex_list_all "$WORK/intents.json" intentSummaries list-intents --bot-id "$BOT_ID" --bot-version DRAFT \
      --locale-id "$LEX_LOCALE" --filters "name=IntentName,values=HelpdeskIntent,operator=EQ"
    intent_id="$(unique_id "$WORK/intents.json" intentSummaries intentName HelpdeskIntent intentId)"
    if [[ -z "$intent_id" ]]; then
      lex create-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" --intent-name HelpdeskIntent \
        --description "Any IT Helpdesk request - the Lambda drives the conversation" \
        --sample-utterances "file://$WORK/utterances.json" --fulfillment-code-hook enabled=true >/dev/null
    else
      lex update-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" --intent-id "$intent_id" \
        --intent-name HelpdeskIntent --description "Any IT Helpdesk request - the Lambda drives the conversation" \
        --sample-utterances "file://$WORK/utterances.json" --fulfillment-code-hook enabled=true >/dev/null
    fi
    # 内置 FallbackIntent 也交给 Lambda：点选的选项和自由输入都由 Lambda 处理
    lex update-intent --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" --intent-id FALLBCKINT \
      --intent-name FallbackIntent --parent-intent-signature AMAZON.FallbackIntent --fulfillment-code-hook enabled=true >/dev/null
    log "Building Lex locale $LEX_LOCALE"
    lex build-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" >/dev/null
    if ! lex wait bot-locale-built --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE"; then
      lex describe-bot-locale --bot-id "$BOT_ID" --bot-version DRAFT --locale-id "$LEX_LOCALE" --query failureReasons >&2 || true
      die "Lex locale build 失败"
    fi
    new_ver="$(lex create-bot-version --bot-id "$BOT_ID" \
      --bot-version-locale-specification "{\"$LEX_LOCALE\":{\"sourceBotVersion\":\"DRAFT\"}}" --query botVersion --output text)"
    lex wait bot-version-available --bot-id "$BOT_ID" --bot-version "$new_ver"
    python3 -c "import json,sys; print(json.dumps({sys.argv[1]:{'enabled':True,'codeHookSpecification':{'lambdaCodeHook':{'lambdaARN':sys.argv[2],'codeHookInterfaceVersion':'1.0'}}}}))" \
      "$LEX_LOCALE" "$BOT_FN_ARN" >"$WORK/alias-locale.json"
    if [[ -z "$alias_id" ]]; then
      log "Creating Lex alias $LEX_ALIAS_NAME -> version $new_ver"
      alias_id="$(lex create-bot-alias --bot-id "$BOT_ID" --bot-alias-name "$LEX_ALIAS_NAME" --bot-version "$new_ver" \
        --bot-alias-locale-settings "file://$WORK/alias-locale.json" --description "def=$def_hash" --query botAliasId --output text)"
    else
      log "Updating Lex alias $LEX_ALIAS_NAME -> version $new_ver"
      lex update-bot-alias --bot-id "$BOT_ID" --bot-alias-id "$alias_id" --bot-alias-name "$LEX_ALIAS_NAME" \
        --bot-version "$new_ver" --bot-alias-locale-settings "file://$WORK/alias-locale.json" --description "def=$def_hash" >/dev/null
    fi
    lex wait bot-alias-available --bot-id "$BOT_ID" --bot-alias-id "$alias_id"
    cleanup_bot_versions
  fi
  LEX_ALIAS_ARN="arn:$PARTITION:lex:$REGION:$ACCOUNT:bot-alias/$BOT_ID/$alias_id"
  add_permission_once "$BOT_FN" "lex-$alias_id" lexv2.amazonaws.com "$LEX_ALIAS_ARN"
  if ! "${AWSC[@]}" connect list-bots --instance-id "$INSTANCE_ID" --lex-version V2 --output json \
      | python3 -c "import json,sys; sys.exit(0 if any((b.get('LexV2Bot') or {}).get('AliasArn')==sys.argv[1] for b in json.load(sys.stdin).get('LexBots',[])) else 1)" "$LEX_ALIAS_ARN"; then
    log "Associating Lex bot alias with the Connect instance"
    "${AWSC[@]}" connect associate-bot --instance-id "$INSTANCE_ID" --lex-v2-bot "AliasArn=$LEX_ALIAS_ARN"
  fi
  note "Lex bot $BOT_NAME ($BOT_ID) alias $LEX_ALIAS_NAME -> version $new_ver, code hook $BOT_FN"
}

cleanup_bot_versions() {  # 删除没有任何别名引用的旧版本（保留 DRAFT）
  local v
  lex_list_all "$WORK/aliases.json" botAliasSummaries list-bot-aliases --bot-id "$BOT_ID"
  lex_list_all "$WORK/versions.json" botVersionSummaries list-bot-versions --bot-id "$BOT_ID"
  # 结果先写文件（bash 3.2 无法正确解析命令替换里的 heredoc）
  python3 - "$WORK/aliases.json" "$WORK/versions.json" >"$WORK/unused-versions.txt" <<'PY'
import json, sys
used = {a.get("botVersion") for a in json.load(open(sys.argv[1])).get("botAliasSummaries", [])}
for x in json.load(open(sys.argv[2])).get("botVersionSummaries", []):
    v = x.get("botVersion")
    if v and v != "DRAFT" and v not in used:
        print(v)
PY
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    lex delete-bot-version --bot-id "$BOT_ID" --bot-version "$v" >/dev/null 2>&1 || warn "未能删除 Lex 旧版本 $v"
  done <"$WORK/unused-versions.txt"
}

# ---------------------------------------------------------------- 7. queues / routing profile
list_queues() { "${AWSC[@]}" connect list-queues --instance-id "$INSTANCE_ID" --queue-types STANDARD --output json >"$WORK/queues.json"; }

ensure_queue() {  # $1 name $2 description
  local qid hours
  list_queues
  qid="$(unique_id "$WORK/queues.json" QueueSummaryList Name "$1" Id)"
  if [[ -z "$qid" ]]; then
    "${AWSC[@]}" connect list-hours-of-operations --instance-id "$INSTANCE_ID" --output json >"$WORK/hours.json"
    hours="$(unique_id "$WORK/hours.json" HoursOfOperationSummaryList Name "$HOURS_NAME" Id)"
    [[ -n "$hours" ]] || die "找不到营业时间 '$HOURS_NAME'（设置 HOURS_NAME）"
    log "Creating queue $1"
    "${AWSC[@]}" connect create-queue --instance-id "$INSTANCE_ID" --name "$1" --hours-of-operation-id "$hours" \
      --description "$2" --tags Project=it-helpdesk-chat-ai >/dev/null
    list_queues
  fi
  note "Queue $1"
}

ensure_routing_profile() {  # $@ queue names served on the CHAT channel
  local rp q qid first
  list_queues
  "${AWSC[@]}" connect list-routing-profiles --instance-id "$INSTANCE_ID" --output json >"$WORK/rps.json"
  rp="$(unique_id "$WORK/rps.json" RoutingProfileSummaryList Name "$ROUTING_PROFILE_NAME" Id)"
  if [[ -z "$rp" ]]; then
    first="$(unique_id "$WORK/queues.json" QueueSummaryList Name "$1" Id)"
    log "Creating routing profile $ROUTING_PROFILE_NAME (Chat channel)"
    rp="$("${AWSC[@]}" connect create-routing-profile --instance-id "$INSTANCE_ID" --name "$ROUTING_PROFILE_NAME" \
      --description "IT Helpdesk chat agents" --default-outbound-queue-id "$first" \
      --media-concurrencies 'Channel=CHAT,Concurrency=3' --query RoutingProfileId --output text)"
  fi
  "${AWSC[@]}" connect list-routing-profile-queues --instance-id "$INSTANCE_ID" --routing-profile-id "$rp" --output json >"$WORK/rpq.json"
  for q in "$@"; do
    qid="$(unique_id "$WORK/queues.json" QueueSummaryList Name "$q" Id)"; [[ -n "$qid" ]] || continue
    if ! python3 -c "import json,sys; sys.exit(0 if any(c['QueueId']==sys.argv[1] and c['Channel']=='CHAT' for c in json.load(open(sys.argv[2])).get('RoutingProfileQueueConfigSummaryList',[])) else 1)" "$qid" "$WORK/rpq.json"; then
      "${AWSC[@]}" connect associate-routing-profile-queues --instance-id "$INSTANCE_ID" --routing-profile-id "$rp" \
        --queue-configs "QueueReference={QueueId=$qid,Channel=CHAT},Priority=1,Delay=0"
    fi
  done
  local u uid
  IFS=',' read -r -a _USERS <<<"$AGENT_USERNAMES"
  for u in ${_USERS[@]+"${_USERS[@]}"}; do
    [[ -n "$u" ]] || continue
    [[ -s "$WORK/users.json" ]] || "${AWSC[@]}" connect list-users --instance-id "$INSTANCE_ID" --output json >"$WORK/users.json"
    uid="$(unique_id "$WORK/users.json" UserSummaryList Username "$u" Id)"
    if [[ -z "$uid" ]]; then warn "找不到坐席 $u"; continue; fi
    "${AWSC[@]}" connect update-user-routing-profile --instance-id "$INSTANCE_ID" --user-id "$uid" --routing-profile-id "$rp"
    note "User $u moved to routing profile $ROUTING_PROFILE_NAME"
  done
  note "Routing profile $ROUTING_PROFILE_NAME serves (CHAT): $*"
}

# ---------------------------------------------------------------- 8. contact flow
publish_flow() {
  local id
  list_queues
  python3 - "$HERE/flow/it_helpdesk_chat_flow.json" "$WORK/flow.json" "$WORK/queues.json" "$QUEUE_IT" "$QUEUE_SECURITY" \
    "$STREAM_FN_ARN" "$LEX_ALIAS_ARN" "$ANALYZE_FN_ARN" <<'PY'
import json, sys
src, dst, qfile, q_it, q_sec, stream_arn, alias_arn, analyze_arn = sys.argv[1:]
queues = {q["Name"]: q["Arn"] for q in json.load(open(qfile))["QueueSummaryList"] if q.get("Name")}
rep = {"__STREAM_LAMBDA_ARN__": stream_arn, "__LEX_ALIAS_ARN__": alias_arn, "__ANALYZE_LAMBDA_ARN__": analyze_arn,
       "__QUEUE_IT_ARN__": queues[q_it], "__QUEUE_IT_NAME__": q_it,
       "__QUEUE_SECURITY_ARN__": queues[q_sec], "__QUEUE_SECURITY_NAME__": q_sec}
def render(n):
    if isinstance(n, dict):
        return {k: render(v) for k, v in n.items()}
    if isinstance(n, list):
        return [render(v) for v in n]
    return rep.get(n, n) if isinstance(n, str) else n
flow = render(json.load(open(src, encoding="utf-8")))
left = [k for k in rep if k in json.dumps(flow)]
assert not left, f"unrendered placeholders {left}"
json.dump(flow, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
PY
  "${AWSC[@]}" connect list-contact-flows --instance-id "$INSTANCE_ID" --contact-flow-types CONTACT_FLOW --output json >"$WORK/flows.json"
  id="$(unique_id "$WORK/flows.json" ContactFlowSummaryList Name "$FLOW_NAME" Id)"
  if [[ -z "$id" ]]; then
    log "Creating flow $FLOW_NAME"
    id="$("${AWSC[@]}" connect create-contact-flow --instance-id "$INSTANCE_ID" --name "$FLOW_NAME" --type CONTACT_FLOW \
      --description "IT Helpdesk chat: Lex interactive messages + Bedrock screenshot analysis" --content "file://$WORK/flow.json" \
      --status PUBLISHED --query ContactFlowId --output text)"
  else
    log "Updating flow $FLOW_NAME ($id)"
    "${AWSC[@]}" connect update-contact-flow-content --instance-id "$INSTANCE_ID" --contact-flow-id "$id" --content "file://$WORK/flow.json"
  fi
  FLOW_ID="$id"
  note "Flow $FLOW_NAME ($FLOW_ID)"
}

# ---------------------------------------------------------------- 9. self-tests（直接调用 bot Lambda，模拟 Lex 事件；不创建真实 chat）
SMOKE_CONTACT=""
SMOKE_S3_KEY=""

smoke_conversation() {  # $1 label, $2 turns JSON（[{"say":..,"expect":python 表达式} | {"upload":本地文件}]）
  [[ "$SKIP_SMOKE" == "true" ]] && return 0
  local label="$1"
  SMOKE_CONTACT="SMOKE-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
  log "Self-test: $label"
  if python3 - "$2" "$SMOKE_CONTACT" "$BOT_FN" "$TABLE_NAME" "$ATTACH_BUCKET" "$ATTACH_PREFIX" "$WORK" "$ANALYZE_FN" "${AWSC[@]}" <<'PY'
import json, os, subprocess, sys, datetime, uuid, time
turns, cid, fn, table, bucket, prefix, work, analyze_fn = sys.argv[1:9]
awsc = sys.argv[9:]
attrs = {"contact_id": cid, "initial_contact_id": cid}
def aws(*a):
    return subprocess.run(awsc + list(a), check=True, capture_output=True, text=True).stdout
for i, turn in enumerate(json.loads(turns)):
    if "upload" in turn:
        aid = "SMOKE" + uuid.uuid4().hex[:10]
        now = datetime.datetime.now(datetime.timezone.utc)
        key = f"{prefix + '/' if prefix else ''}chat/{now:%Y/%m/%d}/{aid}_{now:%Y%m%dT%H:%M}_UTC.png"
        aws("s3api", "put-object", "--bucket", bucket, "--key", key, "--body", turn["upload"], "--content-type", "image/png")
        open(os.path.join(work, "smoke-s3-keys.txt"), "a").write(key + "\n")
        item = {"pk": {"S": f"ATTACH#{cid}"}, "sk": {"S": f"{now.isoformat()}#{aid}"}, "attachment_id": {"S": aid},
                "file_name": {"S": os.path.basename(turn["upload"])}, "content_type": {"S": "image/png"}, "status": {"S": "APPROVED"},
                "absolute_time": {"S": now.isoformat()}, "ttl": {"N": str(int(now.timestamp()) + 3600)}}
        aws("dynamodb", "put-item", "--table-name", table, "--item", json.dumps(item))
        print(f"   [customer uploads {os.path.basename(turn['upload'])}]")
        continue
    def invoke(function, payload):
        inp, out = os.path.join(work, "smoke-in.json"), os.path.join(work, "smoke-out.json")
        json.dump(payload, open(inp, "w"))
        aws("lambda", "invoke", "--function-name", function, "--cli-read-timeout", "90", "--payload", f"fileb://{inp}", out)
        r = json.load(open(out))
        if "errorMessage" in r:
            print("   Lambda error:", r["errorMessage"]); sys.exit(1)
        return r
    def bot_turn(text, attrs):
        return invoke(fn, {"sessionId": cid, "inputTranscript": text, "inputMode": "Text", "invocationSource": "FulfillmentCodeHook",
                           "sessionState": {"sessionAttributes": attrs, "intent": {"name": "HelpdeskIntent", "state": "ReadyForFulfillment"}}})
    r = bot_turn(turn["say"], attrs)
    attrs = r["sessionState"]["sessionAttributes"]
    if attrs.get("next_step") == "ANALYZE":  # emulate the flow: async analysis Lambda, then re-enter the bot
        print(f"   > {turn['say']}")
        for m in r.get("messages", []):
            print(f"     {m['content'][:300]}")
        t0 = time.time()
        a = invoke(analyze_fn, {"Name": "ContactFlowEvent", "Details": {"ContactData": {"ContactId": cid, "Channel": "CHAT"},
                                                                         "Parameters": {"contact_id": cid}}})
        print(f"   [flow: async analysis Lambda -> {a.get('status')} in {time.time() - t0:.1f}s, re-enter bot]")
        marker = "__ANALYSIS_READY__" if a.get("status") else "__ANALYSIS_FAILED__"
        r = bot_turn(marker, {"contact_id": cid, "initial_contact_id": cid})
        attrs = r["sessionState"]["sessionAttributes"]
        turn = dict(turn, say=marker)
    texts, choices = [], []
    for m in r.get("messages", []):
        if m["contentType"] == "CustomPayload":
            c = json.loads(m["content"]); choices = [e["title"] for e in c["data"]["content"]["elements"]]
            texts.append(f"[{c['templateType']}] {c['data']['content']['title']} {choices}")
        else:
            texts.append(m["content"])
    print(f"   > {turn['say']}")
    for t in texts:
        print(f"     {t[:300]}")
    env = {"attrs": attrs, "choices": choices, "texts": texts, "action": r["sessionState"]["dialogAction"]["type"]}
    if turn.get("expect") and not eval(turn["expect"], env):
        print(f"   expected: {turn['expect']}"); sys.exit(1)
PY
  then note "self-test PASS  $label"
  else SMOKE_FAILS=$((SMOKE_FAILS + 1)); note "SELF-TEST FAIL  $label"; fi
}

run_smoke() {
  [[ "$SKIP_SMOKE" == "true" ]] && { note "Self-tests skipped (SKIP_SMOKE=true)"; return 0; }
  SMOKE_RAN=1
  local upload_turns='{"say": "I don'"'"'t have a screenshot", "expect": "\"Reset my password\" in choices"}'
  local img_label="no screenshot"
  if [[ -n "$SMOKE_IMAGE" && -f "$SMOKE_IMAGE" ]]; then
    upload_turns="{\"upload\": \"$SMOKE_IMAGE\"},
      {\"say\": \"done\", \"expect\": \"attrs.get('shot_category') in ('WRONG_PASSWORD','ACCOUNT_LOCKED','PASSWORD_EXPIRED') and 'Reset my password' in choices\"}"
    img_label="screenshot analyzed by $VISION_MODEL_ID"
  fi
  smoke_conversation "Sign-in problem -> $img_label (async) -> verify -> password reset" "[
    {\"say\": \"Hello\", \"expect\": \"'Account & sign-in issues' in choices and 'Talk to an agent' in choices\"},
    {\"say\": \"Account & sign-in issues\", \"expect\": \"\\\"I can't sign in to the intranet\\\" in choices\"},
    {\"say\": \"I can't sign in to the intranet\", \"expect\": \"attrs.get('stage') == 'AWAIT_SCREENSHOT'\"},
    $upload_turns,
    {\"say\": \"Reset my password\", \"expect\": \"attrs.get('stage') == 'AWAIT_EMPLOYEE_ID'\"},
    {\"say\": \"E10001\", \"expect\": \"attrs.get('stage') == 'AWAIT_PHONE_LAST4'\"},
    {\"say\": \"4821\", \"expect\": \"attrs.get('reset_status') == 'LINK_SENT'\"},
    {\"say\": \"Yes, I can sign in now\", \"expect\": \"action == 'Close' and attrs.get('next_step') == 'END'\"}]"
  smoke_conversation "Free text routed by Bedrock + hand-off to agent" "[
    {\"say\": \"Hello\"},
    {\"say\": \"Hi, my docking station stopped charging\", \"expect\": \"attrs.get('stage') == 'HARDWARE'\"},
    {\"say\": \"Talk to an agent\", \"expect\": \"action == 'Close' and attrs.get('next_step') == 'TRANSFER' and attrs.get('target_queue') == 'IT'\"}]"
}

cleanup_smoke() {  # 删除自检写入的 S3 对象和 DynamoDB 记录，并恢复被自检修改的模拟员工记录
  [[ "${SMOKE_RAN:-0}" == 1 && "${SMOKE_CLEANED:-0}" == 0 ]] || return 0
  SMOKE_CLEANED=1
  local key n=0
  if [[ -f "$WORK/smoke-s3-keys.txt" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] && "${AWSC[@]}" s3api delete-object --bucket "$ATTACH_BUCKET" --key "$key" >/dev/null
    done <"$WORK/smoke-s3-keys.txt"
  fi
  "${AWSC[@]}" dynamodb scan --table-name "$TABLE_NAME" --projection-expression "pk, sk" \
    --filter-expression "begins_with(pk, :a) OR begins_with(pk, :e) OR begins_with(pk, :n) OR (begins_with(pk, :r) AND begins_with(contact_id, :s)) OR (begins_with(pk, :v) AND begins_with(contact_id, :s))" \
    --expression-attribute-values '{":a":{"S":"ATTACH#SMOKE-"},":e":{"S":"SESSION#SMOKE-"},":n":{"S":"ANALYSIS#SMOKE-"},":r":{"S":"RESET#"},":v":{"S":"VERIFYFAIL#"},":s":{"S":"SMOKE-"}}' \
    --output json >"$WORK/smoke-items.json"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    "${AWSC[@]}" dynamodb delete-item --table-name "$TABLE_NAME" --key "$key"; n=$((n + 1))
  done < <(python3 -c "import json,sys; [print(json.dumps({'pk': i['pk'], 'sk': i['sk']})) for i in json.load(open(sys.argv[1])).get('Items', [])]" "$WORK/smoke-items.json")
  seed_directory true >/dev/null   # 自检重置过 E10001：恢复为初始状态（locked=true）
  log "Self-test data removed ($n items), mock directory restored"
}

_on_exit() {
  if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
    cleanup_smoke || warn "self-test cleanup failed"
    rm -rf "$WORK"
  fi
}

finish() {
  cleanup_smoke
  printf '\n========== IT Helpdesk chat AI deployed ==========\n'
  local s; for s in ${SUMMARY[@]+"${SUMMARY[@]}"}; do printf '  - %s\n' "$s"; done
  cat <<EOF

手工验收（chat 内容为英文）：
  1. Connect 管理网站 https://$INSTANCE_ALIAS.my.connect.aws -> Flows -> 打开 $FLOW_NAME -> 右上角 "Test chat"
     （或在 Channels -> Communications widgets 中把 widget 的 chat flow 设为 ${FLOW_NAME}，并在 widget 里开启附件）。
  2. 主菜单（ListPicker）选择 "Account & sign-in issues"，再在 Panel 中选择 "I can't sign in to the intranet"。
  3. 用回形针图标上传 samples/wrong_password_screenshot.png（或你自己的登录错误截图），图片出现在对话中后输入 done。
  4. 预期：AI 用英文说明截图中的错误（Incorrect username or password），并给出 Panel：Reset my password / Talk to an agent / Main menu。
  5. Reset my password -> 员工号 E10001 -> 手机后四位 4821 -> 提示重置链接已发送 -> ListPicker 确认是否解决。
  6. 选择 "Talk to an agent"：联系进入 ${QUEUE_IT}；坐席（路由配置文件 ${ROUTING_PROFILE_NAME}）在联系属性中看到 ai_summary 等字段。
  7. 上传登录页地址不在 TRUSTED_DOMAINS 中的截图：AI 提示疑似钓鱼并转 ${QUEUE_SECURITY}。
  模拟员工：E10001/4821（已锁定）、E10002/7305、E10003/1190（已停用，转人工）。
EOF
  [[ "$SMOKE_FAILS" -eq 0 ]] || { printf '\n%s 个自检失败，请查看 CloudWatch 日志 /aws/lambda/%s。\n' "$SMOKE_FAILS" "$BOT_FN"; exit 2; }
}

# ================================================================ main
init_env
ensure_attachment_storage
ensure_chat_attachment_types
ensure_table
seed_directory
ensure_topic
ensure_roles
deploy_lambdas
ensure_bot
ensure_queue "$QUEUE_IT" "IT Helpdesk chat - general"
ensure_queue "$QUEUE_SECURITY" "IT Helpdesk chat - security (phishing, failed identity verification)"
ensure_routing_profile "$QUEUE_IT" "$QUEUE_SECURITY"
publish_flow
run_smoke
finish
