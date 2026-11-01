# MiDrop 0.4 协议

Mac 为唯一网络监听端，提供 TLS 1.2+ HTTPS。手机主动连接。Bonjour 发布 `_midrop._tcp.`，TXT 中的 `id` 为 Mac 证书 SHA-256 前 24 位，仅作发现标识，不能代替完整证书验证。

## 身份与兼容

- `GET /health` 返回兼容旧版的 `protocol: 1`，新增 `api: 2`、`server_id` 与能力列表。
- 0.3.0 在能力列表中加入 `text`；原文件接口和 API 版本保持兼容。
- `devices.json` 保留原来的令牌哈希 → 设备名称结构，不写入原始令牌；新设备元数据单独保存在 `device_meta.json`。
- `POST /pair` 保留旧版接口，供兼容和回归测试；新版 UI 不展示配对码。
- 新版初次只探测证书和提交请求；Mac 本机批准后，手机取得令牌并固定此前完整证书指纹。请求名称为对端声明，不是账号认证。

## 新建信任

- `POST /trust/request`：`name`、`client_id` → 随机 `request_id`、私密 `ticket`，有效期 60 秒。
- `POST /trust/status`：提交 ID 和 ticket，返回 pending / approved / rejected / expired。只有 approved 才提供令牌，且只保留至短期领取期限。
- 全局每分钟至多五次请求，最多五个待处理请求。过期后不可批准。
- **网络 API 不提供批准操作**。Mac UI 只能通过本机 Unix Socket 的 `approve` 操作批准。

## 会话与双向传输

已信任请求携带 `Authorization: Bearer …`，设备身份从令牌推导，不能通过请求中的设备 ID 选择其他设备。

- `POST /events`：提交是否可接收，记录在线状态，长轮询返回本设备待接收批次。最后心跳超过 60 秒视为离线。
- `POST /upload?name=…`：手机发送原始字节；长度及 `X-Content-SHA256` 必填，`X-Transfer-ID` 可指定取消标识。旧版未携带标识时服务端自动生成。
- 本机 `queue` 操作：选择可信且可接收的手机，异步预校验文件并创建批次，准备完成后等待接收端接手，120 秒过期。
- `POST /offers/{id}/decision`：本设备 accept / reject。Android 0.2.2 在已配对且连接、接收开启且具备保存权限时自动发送 accept，无需用户逐次确认；串行接收批次，后台关闭后只在前台接收。通知权限不作为接收条件。保留 reject 以兼容旧客户端。
- `GET /files/{batch}/{file}`：只能由批次所属设备，在完成 accept 握手且未结束时下载。服务端再次检查源文件大小和修改时间。
- `POST /offers/{id}/ack`：接收端校验并保存后，逐文件提交 ID 与 SHA-256。所有文件确认才完成批次。
- `POST /offers/{id}/cancel`、`POST /transfers/{id}/cancel`：取消本设备的传输；批次中已保存的完整文件保留。

传输状态统一为 preparing、waiting、accepted、transferring、completed、rejected、cancelled、expired、failed。已接受但五分钟无进展的批次失败，不自动续传。

## 共享公告板

- 全体已配对设备共享同一个当前文档，不需要收件设备，也不产生消息历史。UTF-8 上限 64 KiB，允许空内容用于同步清空；中文、emoji、空格、换行原样保存。
- `GET /board`：已认证手机读取当前 `{text, revision, updated}`。
- `POST /board`：提交 `{text, base_revision}`。Mac 本机 Socket 对应 `{action:"update_board",text,base_revision}`，无需 device_id。正文相同时幂等返回当前版本；正文不同且版本过期时返回 409 和当前 board，不覆盖新内容。成功更新持久化后递增 revision，并唤醒等待中的所有已配对客户端。
- `/events` 请求增加 `board_support:true` 和客户端已知 `board_revision`，响应包含当前 board。已知版本相同且无文件事件时正常长轮询；版本不同立即返回。公告板不受文件接收开关或保存权限影响，只需保持已认证连接。客户端停止后台连接后不再实时更新，重连自动读取最新版本。
- 客户端编辑停顿约 0.6 秒后自动更新。未同步草稿保留；收到新版本时不覆盖本地脏草稿。陈旧写入冲突后保留草稿并暂停自动覆盖，用户可使用远端内容，或继续编辑以最新版本为基准同步。
- Mac 仅保存当前 `board.json` 和有待同步时的 `board-draft.json`（0600）；Android 在私有偏好保存当前文档与待同步草稿。没有公告板历史队列、逐条投递确认或 120 秒消息过期。
- 链接作为普通文字；只有完整 HTTP/HTTPS 地址提供显式打开入口，不自动改写剪贴板或启动浏览器。
- 0.3 旧版 `/texts` 消息接口暂保留兼容，0.4 界面与同步服务不使用它、不展示或自动广播旧文字记录。

## 本机边界与保存

`~/Library/Application Support/MiDrop` 权限 0700；私钥、凭据、状态和 `control.sock` 权限 0600。

Unix Socket 接受一行 JSON，支持 snapshot、approve、queue、update_board、revoke、cancel（兼容旧 send_text）。状态快照不包含 ticket、原始令牌或可直接授权的秘密。

Mac 共享扩展运行于独立沙盒，通过 Launch Services 交给主 App：文件 URL 使用文档打开事件；纯文本和网页链接使用 `midrop://share-text?text=…` URL（64 KiB 上限）。扩展不读取凭据或连接控制 Socket；文件在主 App 中暂存并选择手机发送；文字/链接直接写入共享公告板后自动同步。文件与文字混合选择不激活扩展。主 App 声明接收 `public.data` 文档以允许沙盒扩展交接，`LSHandlerRank=None` 不参与默认打开方式的选择。

Mac 临时文件完整接收和校验后，使用不可覆盖的原子硬链接提交到下载目录。Android 10+ 先写入 `IS_PENDING=1` 的 MediaStore 条目，长度与 SHA-256 符合后才发布；取消或失败则删除条目，进程异常退出后下次启动清理记录的未完成条目。

接收成功但确认响应丢失时，文件仍保留，发送端可能显示失败；再次发送会产生副本。服务重启不恢复未完成批次。
