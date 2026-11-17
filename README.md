# IT Helpdesk Chat AI（Amazon Connect chat 渠道）

场景：员工无法登录公司内网，在 chat 中上传"密码错误"截图，AI 客服用 Bedrock 多模态模型分析截图，验证身份后重置密码。主菜单还提供"硬件和外设故障"（上传照片分析）和"转人工客服"。chat 中的所有交互都使用英文。

部署脚本支持中文交互选择实例和前缀，每一步可重复执行，选择保存在 `.deploy_settings`，部署后自动跑自检。

## 对话流程

```
Chat 开始 ─ flow: 开启消息流(StartContactStreaming→SNS) ─ Get customer input (Lex V2, 初始消息 "Hello")
  └ ListPicker  How can I help you today?
       ├ Account & sign-in issues ─ Panel
       │    ├ I can't sign in to the intranet ─ "请用回形针上传截图" + Panel
       │    │     ├ 上传后输入 done ─ "I'm analyzing your screenshot now…" ─ flow 异步调用分析 Lambda（Bedrock）─ 结果回到 bot
       │    │     │     ├ WRONG_PASSWORD / ACCOUNT_LOCKED / PASSWORD_EXPIRED ─ Panel: Reset my password / Talk to an agent / Main menu
       │    │     │     ├ 登录页域名不在 TRUSTED_DOMAINS ─ 提示疑似钓鱼 ─ 转 IT-Security 队列
       │    │     │     ├ MFA_FAILURE / ACCOUNT_DISABLED ─ 转人工
       │    │     │     └ 不是登录页 / 看不清 ─ 请重新上传（3 次后转人工）
       │    │     └ I don't have a screenshot ─ Panel: Reset my password ...
       │    ├ My account is locked ─ 同上（上传截图）
       │    └ MFA or verification code issue ─ 转人工
       │  Reset my password ─ 员工号 (E12345) ─ 注册手机后四位 ─ 解锁 + 发送一次性重置链接
       │    └ ListPicker: Yes, I can sign in now (结束) / No, I still can't sign in (转人工) / Main menu
       ├ Hardware & peripherals ─ 上传照片 ─ Bedrock 分析照片并给出排查建议 ─ Panel: Talk to an agent / Main menu / End chat
       ├ Talk to an agent ─ 转 IT-Helpdesk 队列
       └ End chat
```

- 截图和照片的分析是异步的：bot 先回复 "I'm analyzing your screenshot now…" 并把会话交还 flow，flow 用 Asynchronous 模式调用分析 Lambda，等到结果后再带着结果回到 bot（见下文"异步分析"）。
- 用户点选的选项以标题文本回传给 bot；用户直接打字时，先按关键词判断，判断不了再用 Bedrock 文本分类（`route_text`）。
- 任何时候输入 "agent" / "human" 都会转人工，输入 "menu" 回到主菜单。
- 上传图片后用户需要输入 `done`（任意文字都可以）：widget 只在最新一条消息上显示交互按钮，上传文件后按钮就消失了，而且 bot 收不到"已上传"事件。所以等待上传时，bot 把用户的下一条文字当作"已上传"，去查附件；没找到就再提示一次（3 次后转人工）。这一步的 Panel 只保留 "I don't have a screenshot" / "Talk to an agent"。
- 转人工时，bot 通过 `UpdateContactAttributes` 写入 `ai_summary`、`ai_screenshot_category`、`ai_screenshot_error`、`ai_employee_id`、`ai_identity_verified`、`ai_reset_status` 等联系属性，坐席在 CCP / Agent Workspace 中能看到，也能直接打开用户上传的截图。
- 身份验证每个 chat 最多失败 3 次，同一员工号 1 小时内最多失败 5 次（跨 chat），超出后转 IT-Security 队列。bot 不会要求用户提供密码，日志中也不记录员工号和手机后四位的输入。

## 架构

| 组件 | 作用 |
|---|---|
| Connect flow `<P>-IT-Helpdesk-Chat` | 设置 en-US → 调用 stream Lambda 开启消息流 → Get customer input（Lex V2）→ 按 Lex 会话属性 `next_step` / `target_queue` 转队列或结束 |
| Lex V2 bot `<P>-IT-Helpdesk-Bot`（en_US，别名 `live`） | `HelpdeskIntent` 和 `FallbackIntent` 都开启 fulfillment code hook，对话完全由 bot Lambda 驱动 |
| Lambda `<p>-chat-ai-bot` | 对话状态机，返回 interactive messages（ListPicker / Panel，作为 Lex `CustomPayload`）；需要分析图片时把会话交给 flow |
| Lambda `<p>-chat-ai-analyze` | 由 flow 以 Asynchronous 模式调用：从 S3 读截图/照片，调用 Bedrock Converse（Claude Sonnet 4.6）分析，结果写入 DynamoDB |
| Lambda `<p>-chat-ai-stream` | ① 被 flow 调用执行 `StartContactStreaming`；② 订阅 SNS，记录客户上传的附件（联系 ID → 附件 ID） |
| SNS `<p>-chat-ai-stream` | chat 消息流。topic policy 只允许本 Connect 实例发布 |
| DynamoDB `<p>-chat-ai` | 模拟员工目录 `USER#`、附件索引 `ATTACH#`、异步分析前保存的对话状态 `SESSION#`、分析结果 `ANALYSIS#`、重置记录 `RESET#`、验证失败 `VERIFYFAIL#`（TTL 自动清理） |
| Connect ATTACHMENTS 存储（S3） | 用户上传的截图。bot Lambda 只有 `<prefix>/chat/*` 的只读权限 |
| 队列 `<P>-IT-Helpdesk` / `<P>-IT-Security`，路由配置文件 `<P>-IT-Helpdesk-Agents`（CHAT） | 人工接手 |

Lex bot 本身收不到附件，Connect Participant API 也只允许聊天参与者下载附件，所以 bot 用这种方式拿到截图：flow 开启消息流 → SNS 收到客户的附件消息 → stream Lambda 记录附件 ID → 用户上传后输入 "done"（或任意文字）后，bot Lambda 按附件 ID 在 ATTACHMENTS 桶的 `<prefix>/chat/YYYY/MM/DD/<附件ID>_*` 下找到文件，交给 Bedrock。

## 异步分析

Lex code hook 默认只能运行 30 秒，Lex 的 fulfillment updates（"请稍候"提示）只用于语音流式会话，chat 中不会显示。所以图片分析不在 bot 的 code hook 里做，而是交给 flow：

```
bot: "Thanks! I'm analyzing your screenshot now..."，保存对话状态到 SESSION#，Close（next_step=ANALYZE）
 └ flow CheckNextStep = ANALYZE
     └ InvokeAnalysis    AWS Lambda function，Execution mode = Asynchronous，Timeout 60 s，JSON
         └ WaitAnalysis  Wait 2 s
             └ LoadAnalysis  Load Lambda result（$.LambdaInvocation.InvocationId）
                 ├ InProgress → 回到 WaitAnalysis
                 ├ 成功        → ResumeBotReady  Get customer input，初始消息 __ANALYSIS_READY__
                 └ 出错/超时   → ResumeBotFailed Get customer input，初始消息 __ANALYSIS_FAILED__（bot 转人工）
```

bot 收到 `__ANALYSIS_READY__` 后从 DynamoDB 恢复对话状态、读取 `ANALYSIS#` 结果，直接发出分析说明和下一步的 Panel，用户不需要输入任何内容。

关于 Wait 模块：控制台的 Wait 模块有 "Set event based wait → Lambda returned" 选项，但 flow language 的公开文档没有给出它的 JSON 写法，用 API 校验时 `Wait` 的 `Events` 只接受 `CustomerReturned` / `BotParticipantDisconnected`。所以这里用"Wait 2 秒 + Load Lambda result 的 `InProgress` 分支"循环，效果相同：结果最多晚 2 秒被取到；异步调用超过 60 秒时 Load Lambda result 走出错分支，循环结束。整个 flow（包括 `InvocationType: ASYNCHRONOUS`、`LoadLambdaFunctionResult`）已在 us-west-2 的 Connect 实例上以 PUBLISHED 状态通过校验。

## 文件

```
deploy_chat.sh                     部署脚本（中文交互，可重复执行）
flow/it_helpdesk_chat_flow.json    Connect chat flow（占位符在部署时替换）
lex/helpdesk_intent.json           HelpdeskIntent 示例语句
lambda/bot.py                      Lex code hook：对话状态机、转人工、联系属性
lambda/templates.py                ListPicker / Panel 构造（检查 Lex 单条消息 1000 字符上限）
lambda/analyze.py                  异步分析 Lambda（flow 以 Asynchronous 模式调用）
lambda/vision.py                   Bedrock Converse：截图/照片分析（多模态）、自由文本路由、钓鱼域名判断
lambda/attachments.py              附件索引与 S3 读取
lambda/stream.py                   StartContactStreaming + SNS 附件记录
lambda/directory.py                模拟员工目录与密码重置（生产环境替换为 Entra ID / AD 接口）
lambda/common.py                   配置、DynamoDB（CHAT_LOCAL=1 时用内存表做本地测试）
lambda/data/seed_users.json        模拟员工
samples/wrong_password_screenshot.png  测试截图（intranet.example.com，"Incorrect username or password"）
samples/unrelated_sales_report_screenshot.png  与登录无关的测试截图（销售报表），bot 应请用户重新上传
tools/try_screenshot.py            不开 chat，直接按 flow 的顺序用已部署的 bot 测试截图（可连续传多张），测试数据自动删除
```

## 前置条件

- AWS CLI v2、python3（macOS 自带的 bash 3.2 即可）；凭证所属账号与 Connect 实例一致。
- Connect 实例已启用 chat。附件存储：已配置 ATTACHMENTS 时直接使用；未配置时设置 `ATTACHMENT_BUCKET_NAME`，脚本会创建私有加密桶并关联（等同控制台 Data storage → Enable attachments sharing）。

### 附件配置与官方文档的对应（[Enable attachments](https://docs.aws.amazon.com/connect/latest/adminguide/enable-attachments.html)）

| 文档步骤 | 脚本 | 说明 |
|---|---|---|
| 1. Enable attachments sharing | `deploy_chat.sh` | 已有 ATTACHMENTS 存储则沿用，否则用 `ATTACHMENT_BUCKET_NAME` 建桶并关联 |
| 1. staging 前缀 1 天生命周期（建议项） | 不做 | 前缀写错会删除整个桶的 transcript 和附件，需要时请在 S3 控制台只对 `<附件前缀>/staging` 设置 |
| 2. 安全配置文件的 File attachments 权限 | 不做 | 只影响管理员能否在 Settings → Attachments 查看/修改设置，与客户上传无关。需要时在 Users → Security profiles → Settings → File attachments 中授予 |
| 3. 各渠道文件类型和大小 | `deploy_chat.sh` | 检查 CHAT 渠道是否允许 png / jpg / jpeg，缺少的补上（不删除已有类型、不改大小上限）；大小上限低于 4 MB 时警告 |
| 4. 附件桶 CORS | `deploy_chat.sh` + `setup_widget.sh` | 部署脚本追加坐席端来源 `https://<实例别名>.my.connect.aws`；widget 脚本追加页面来源（默认 `http://localhost:<PORT>`，用 `PAGE_ORIGINS` 指定正式网站）。都只追加，不改已有规则 |

bot 能分析的格式是 png / jpg / jpeg / jfif / gif / webp。CHAT 渠道默认允许的 heic（iPhone 照片）Bedrock 不支持，bot 会请用户改传 PNG 或 JPG。
- 实例所在区域已开通 Claude Sonnet 4.6 的模型访问（Anthropic 模型首次使用需要在 Bedrock 控制台提交 use case）。默认模型 ID：us-*/ca-* 区域用 `us.anthropic.claude-sonnet-4-6`，eu-* 用 `eu.`，其他区域用 `global.`。截图分析和自由文本路由都用这个模型，可以用 `VISION_MODEL_ID` / `TEXT_MODEL_ID` 覆盖。
- 区域支持 Amazon Lex V2。

## 执行

```bash
./deploy_chat.sh
```

脚本会用中文询问 Connect 实例 ARN（回车选 `list` 可从列表选择）和资源前缀（默认 `ith`），列出全部资源名称，确认后才开始部署。

非交互运行：

```bash
CONNECT_INSTANCE_ARN='arn:aws:connect:us-west-2:<acct>:instance/<id>' NAME_PREFIX=ith ASSUME_YES=true \
ATTACHMENT_BUCKET_NAME=<仅在未配置附件存储时需要> ./deploy_chat.sh </dev/null
```

常用变量（完整列表见脚本开头）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `VISION_MODEL_ID` | 按区域的 Claude Sonnet 4.6 | 多模态模型 |
| `COMPANY_NAME` | Example Corp | 出现在英文对话中 |
| `TRUSTED_DOMAINS` | intranet.example.com,login.example.com,login.microsoftonline.com | 官方登录域名，换成你们自己的 |
| `AGENT_USERNAMES` | 空 | 这些坐席会被改到 `<P>-IT-Helpdesk-Agents` 路由配置文件 |
| `RESEED_DIRECTORY` | false | true 时重写模拟员工目录 |
| `SKIP_SMOKE` / `SMOKE_IMAGE` | false / samples 截图 | 自检开关 / 自检用的截图 |

## 自检（脚本最后自动执行）

直接调用 bot Lambda 模拟 Lex 事件，不创建真实 chat：

1. 主菜单 ListPicker → 账号 Panel → 上传 `samples/wrong_password_screenshot.png`（脚本把它放进附件桶并写入附件索引）→ bot 交给 flow 分析（自检按 flow 的顺序调用分析 Lambda，再以 `__ANALYSIS_READY__` 回到 bot）→ Bedrock 识别为 `WRONG_PASSWORD` → 员工号 E10001 + 后四位 4821 → 重置链接已发送 → 结束。
2. 自由文本 "my docking station stopped charging" 经 Bedrock 分类为硬件问题 → 转人工（IT 队列）。

自检数据会被删除，模拟员工 E10001 会恢复为初始状态。任何一项失败时脚本以退出码 2 结束。

## 人工验收

- [ ] Connect 管理网站 → Flows → `<P>-IT-Helpdesk-Chat` → Test chat（或把 communications widget 的 chat flow 设为它，并在 widget 设置中允许附件）。打开后先看到英文问候和 ListPicker 主菜单。
- [ ] Account & sign-in issues → I can't sign in to the intranet → 用回形针上传 `samples/wrong_password_screenshot.png` → 图片出现在对话中后输入 `done`：AI 用英文说明 "Incorrect username or password"，给出 Reset my password Panel。
- [ ] Reset my password → `E10001` → `4821`：提示账号已解锁、重置链接已发送到 `a***@example.net`，再出现 ListPicker 确认是否解决。
- [ ] 上传 `samples/unrelated_sales_report_screenshot.png`：AI 说明这张图是销售报表、不是登录错误，请重新上传；连续 3 次传错转人工。也可以不开 chat 直接测：`python3 tools/try_screenshot.py samples/unrelated_sales_report_screenshot.png samples/wrong_password_screenshot.png`。
- [ ] 后四位连续输错 3 次：转 `<P>-IT-Security`。`E10003 / 1190`（已停用）：转人工。
- [ ] 上传地址栏不在 `TRUSTED_DOMAINS` 中的登录页截图：AI 提示疑似钓鱼，转 `<P>-IT-Security`。
- [ ] Talk to an agent：坐席（路由配置文件 `<P>-IT-Helpdesk-Agents`）接起后，在联系属性中看到 `ai_summary` 等字段，能打开用户上传的截图。
- [ ] Hardware & peripherals → 上传设备照片 → AI 给出英文排查建议。

## 网页 widget（setup_widget.sh）

Connect 没有创建 communications widget 的公开 API，所以 widget 在管理网站中创建一次（Channels → Communications widgets → Add communications widget）：

- chat flow 选 `<P>-IT-Helpdesk-Chat`；
- Allowed domains 添加 `http://localhost:8080`（协议和端口必须完全一致）；
- 不启用 security（JWT），否则本地页面没有签发 token 的服务端，chat 无法开始。

把生成的代码片段保存为 `web/widget_snippet.html`（或运行脚本时按提示粘贴；格式见 `web/widget_snippet.example.html`）。`web/widget_snippet.html`、生成的 `web/index.html` 和 `.deploy_settings` 含有你的实例和账号信息，已在 `.gitignore` 中排除，不要提交到公开仓库。然后：

```bash
./setup_widget.sh            # 检查并生成 web/index.html，询问是否在 http://localhost:8080 启动本地服务
PORT=9000 SERVE=false ./setup_widget.sh </dev/null   # 非交互；端口改了也要加到 Allowed domains
```

脚本会把页面来源（默认 `http://localhost:<PORT>`，可用 `PAGE_ORIGINS` 指定）追加到附件桶的 CORS，允许 PUT / GET（附件文档第 4 步），并检查：片段属于 `.deploy_settings` 中的实例、`supportedMessagingContentTypes` 包含 interactive message（否则 ListPicker / Panel 会显示成原始 JSON）、没有启用 JWT、widget 脚本可访问、实例已启用附件、flow 和 Lex bot 已部署。然后用 `web/index.template.html` 生成英文的 IT Helpdesk 页面，嵌入 widget 片段，并把测试截图复制到 `web/`，页面上提供下载链接。widget 用哪个 flow、允许哪些域名无法通过 API 读取，脚本最后会提示到控制台确认。

## 已知限制与需要在你的环境中确认的点

- **附件定位**：bot 按 `<ATTACHMENTS 前缀>/chat/YYYY/MM/DD/<附件ID>_...` 查找文件（这是 Connect 文档中 chat 附件的存储格式）；找不到时会扫描当天目录中包含该附件 ID 的对象。如果你的实例开启了附件扫描或使用了不同的路径，第一次真人测试时请查看 CloudWatch 日志中是否有 `attachment_not_in_s3`。
- **Lex 单条消息 1000 字符**：ListPicker / Panel 不带图片、副标题很短；`templates.py` 会检查长度，超长会报错，不会发出被截断的消息。
- **分析耗时**：一次截图分析实测 3–4.5 秒（Claude Sonnet 4.6，1280×800 PNG，us-west-2）。异步调用最长 60 秒（Connect 的上限），分析 Lambda 超时设为 55 秒，Bedrock 读超时 20 秒；超时或失败时 bot 转人工，坐席可以直接打开截图。
- **分析期间用户发的消息**：flow 在 Wait / Load 循环中，这期间用户输入的文字不会被 bot 处理（通常只有几秒）。
- **图片要求**：PNG / JPG / GIF / WebP，不超过 3.75 MB（Bedrock Converse 的限制）。HEIC 等其他格式会提示用户改传 PNG 或 JPG。
- **密码重置是模拟实现**：`directory.py` 在 DynamoDB 中解锁账号、标记"下次登录必须改密码"，生成一次性令牌（只保存 SHA-256），但不会真的发邮件。接入生产环境时，请把 `find_user` / `reset_password` 换成 Microsoft Graph（Entra ID）或 AD 的接口，并通过 SES 或身份平台自带的流程发送重置链接。chat 中不会显示也不会要求用户提供密码。
- **SNS topic 未开启 SSE**：如果要求加密，需要使用客户托管 KMS 密钥，并在密钥策略中允许 `connect.amazonaws.com` 使用该密钥（AWS 托管的 `aws/sns` 密钥不支持）。
- **初始问候**：flow 用 Get customer input 的 "Initialize bot with message"（初始消息 `Hello`）让 bot 一开始就发出 ListPicker；如果某个渠道不支持，flow 会退回到不带初始消息的 Get customer input，提示用户输入 "menu"。
