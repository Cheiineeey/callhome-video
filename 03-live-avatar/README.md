# 03 · ta 那一格：实时数字人

第三方实时数字人照着 ta 的声音动嘴。我们用的是 [Vivix](https://vivix.ai)，免费档每月 10 分钟，按秒计费。
这一章是坑最多的一层，也是最容易白烧钱的一层。

## 这一篇讲什么

1. [最重要的一条：声音不从网页出](#1-最重要的一条声音不从网页出)
2. [链路](#2-链路)
3. [什么时候连着、什么时候断](#3-什么时候连着什么时候断)
4. [凭证和额度](#4-凭证和额度)
5. [怎么调试才不烧钱](#5-怎么调试才不烧钱)
6. [这一章的坑](#这一章的坑)

---

## 1. 最重要的一条：声音不从网页出

数字人跑在 `WKWebView` 里。网页的声音在另一个进程，**绕过通话的回声消除**。麦克风会把 ta 的声音当成你在插话，ta 一开口就把自己打断。

所以：

- 每一句照旧走你自己的语音合成，拿回 mp3。
- 同一段 mp3 转 base64 送给数字人，**只让它对嘴型**；网页不订阅远端音频。
- 收到「开始渲染」还不能出声：那只是服务端开工，不代表新画面已经到手机。等 `<video>` **真的出现新帧**，再由本地播放器出声；超时才兜底放行（见坑 3.13）。

顺带的好处：光档读的是本地播放器音量，三档共用一个声源。

## 2. 链路

```
app                         你的服务器                     数字人服务
 │ POST /live/session  ───▶  用真钥匙开一场  ─────────────▶
 │ ◀─── 单场临时凭证 ───────                                │
 │ WKWebView 用临时凭证进房 ──────────────────────────────▶ │
 │ 每句：mp3 → response.create(只对嘴型) ─────────────────▶ │
 │ ◀──── render.started → 手机收到真实新帧 / done ────────  │
 │ POST /live/close    ───▶  关场 + 记账                    │
```

- 会话设置：`turn_detection: manual`（不让它自己听、自己回）。
- 进房：`autoReceiveAudio: false`，只拉画面。
- 同一时刻只能排一个回复，所以一次只送一句：上一句本地播完才送下一句。

### 2.1 一步一步怎么连

下面是我们真在跑的那套，字段名照 Vivix 的接口原样写。钥匙、图片地址、音色 id 换成你自己的。

**① 服务器开一场。** 真钥匙只在这一步出现：

```js
// POST https://api.vivix.ai/v1/realtime-avatar/sessions
// Authorization: Bearer <你的 Vivix 钥匙>
{
  model: "vivix-a1-stream",
  output: { aspect_ratio: "9:16", resolution: "480p" },
  max_duration_seconds: 300,                       // 不超过这个月剩的秒数
  auto_close: {
    disconnected_timeout_seconds: 10,              // 网页掉线 10 秒自己关
    interaction_idle_timeout_seconds: 180          // 不能大于 max_duration_seconds，否则 422（坑 3.3）
  },
  conversation: { turn_detection: { type: "manual" } },   // 不让它自己听、自己回
  avatars: [{ avatar_id: "ta", visual: {
    default_source_image_id: "calm",
    source_images: [                               // 可以放多张，场中切（坑 3.12）
      { source_image_id: "calm", url: "https://…/calm.jpg", media_type: "image/jpeg", description: "一句英文描述这张脸" },
      { source_image_id: "grin", url: "https://…/grin.jpg", media_type: "image/jpeg", description: "…" }
    ] } }],
  // 嘴型照我们推过去的音轨动，它自己的 TTS 不开口；但 tts_config 不填齐不让开场。
  // 我们填的是一套 ElevenLabs（单开一把专用钥匙，日志里替换成 ***），实际从来不用它出声
  pipeline_config: { tts_config: { tts_provider: "elevenlabs", tts_model_id: "eleven_v3",
    tts_voice_id: "<音色 id>", tts_api_key: "<ElevenLabs 钥匙>" } }
}
```

返回里有用的两块，原样转给 app，app 再塞给网页：

```js
{
  session_id: "…",
  control:  { url: "wss://…", client_secret: "…" },          // 控制通道：说话、换脸、取消
  delivery: { media: { trtc: {                                // 画面：腾讯 TRTC 房间
    sdk_app_id, room_id, user_id, user_sig, publisher_user_id // publisher 是数字人那一路
  } } }
}
```

app 拿这份要用自己的鉴权去换（我们是 `POST /live/session` 带一个 Bearer），别让 app 直连 Vivix。

**② 网页连控制通道。** 临时凭证放在 query 里：

```js
const url = new URL(s.control.url);
url.searchParams.set("token", s.control.client_secret);
ws = new WebSocket(url);           // 15 秒没 open 就当连不上
```

**③ 网页进 TRTC 房间，只拉画面。** 用 `trtc-sdk-v5`，esbuild 打成一个 bundle 让 `WKWebView` 加载：

```js
rtc = TRTC.create();
rtc.on(TRTC.EVENT.REMOTE_VIDEO_AVAILABLE, ({ userId, streamType }) => {
  if (userId === m.publisher_user_id)       // 房里可能不止一路，只要数字人那路
    rtc.startRemoteVideo({ userId, streamType, view: "v", option: { fillMode: "cover" } });
});
await rtc.enterRoom({
  sdkAppId: Number(m.sdk_app_id), userId: m.user_id, userSig: m.user_sig, strRoomId: m.room_id,
  scene: TRTC.TYPE.SCENE_RTC,
  autoReceiveVideo: false,                  // 手动 startRemoteVideo
  autoReceiveAudio: false                   // 声音不收（第 1 节）
});
```

「画面到了」别只等 `FIRST_VIDEO_FRAME`：手机上它有时不来。我们另外每 300ms 看一眼 `#v video`，`videoWidth > 0 && readyState >= 2 && !paused` 也算到了；停着就自己 `play()` 一下。

**④ 每一句：把 mp3 送过去对嘴型。**

```js
ws.send(JSON.stringify({
  event_id: "say_" + n, type: "response.create",
  response: { conversation: "none",
    script: { vocal: { type: "audio", mime_type: "audio/mpeg", audio: base64Mp3 } } }
}));
```

回来的事件按顺序是：

| 事件 | 意思 | 我们做什么 |
|---|---|---|
| `response.created` | 收下了，带 `response.id` | 跟刚送的那句对上（一次只送一句，先来后到就对得上） |
| `response.render.started` | 服务端开始画 | 等手机上真出新帧再让 app 出声（坑 3.13） |
| `response.done` | 这句画完了，带 `status` | 告诉 app 可以送下一句（坑 3.6：别指望它带你的编号） |
| `session.update.done` | 换脸完成，带 `status` | 这时才改 app 里记的当前脸 |
| `error` / `session.closed` | 出错 / 场子没了 | 退回垫底层 |

插话：`{ type: "response.cancel" }`。换脸：`{ type: "session.update", session: { source_image_id: "grin" } }`。

**⑤ 关场。** 网页先 `ws.close()`、`rtc.exitRoom()`、`rtc.destroy()`；app 再叫服务器 `POST https://api.vivix.ai/v1/realtime-avatar/sessions/<session_id>/close`（同一把钥匙），然后记账（第 4 节）。

网页和 app 之间就是几个全局函数加一个 message handler：

```
app → 网页：start(凭证) / say(编号, base64) / face(id) / cancel() / stop()
网页 → app：webkit.messageHandlers.vx.postMessage({ ev: "loaded" | "ready" | "started" | "done" | "face" | "error" | "closed", … })
```

## 3. 什么时候连着、什么时候断

接通就开场、挂断才关 = 一通电话烧光一个月。所以要断，但**别按轮断**——我们按轮断了一周，越省越亏（见坑 3.9）。

现在的做法：

- 你说完、请求发给模型的那一刻就去开场（跟模型写稿、语音合成并行）。所以 ta 想的那几秒本来就连着。
- 第一句来了画面还没好：最多等 5 秒，等不到**先出声**，画面后几句再跟上。声音永远不被画面卡。
- **ta 说完后多久没人开口才关场，做成设置。**我们设的一分钟：正常一来一回不断，真安静了才省。不在乎额度的，可以设成永不断（挂断才关）；额度特别紧的可以调短，但别短于两轮之间的空隙，先看坑 3.9 再定。
- 开场请求带一个代数计数：请求还在路上就被关了的，回来直接还掉。
- 同一时刻只开一场：服务器上开场要排队，前一个落地了再开下一个（见坑 3.10）。
- 通话页缩小时不开场，缩小 / 离开页面时关掉。

**底层垫什么**：开场那几秒、一分钟没人说话断开之后、连不上、额度用完——这些时候露出来的是垫底层。最底下是照片（必须就是数字人的源图），照片上面可以垫一段从数字人自己身上录的几秒无缝循环（见坑 3.12），这样断开的时候画面不会变成死图。

## 4. 凭证和额度

- 真钥匙只在服务器上。app 和网页只拿单场临时凭证。
- 打日志前把钥匙替换成 `***`。
- 数字人服务**没有查用量的接口**，额度只能自己记，以它后台为准。
- 我们对过账单得出的事实：
  - 按秒，没有起步价（开了马上关记 3~4 秒）。
  - **从开场请求发出那一刻起计时**，不是返回那刻。
  - 关场后还有约 10 秒尾巴。

## 5. 怎么调试才不烧钱

- 别反复真开场。先用 node 直连 WebSocket 跑一次十几秒的探针，或者无头浏览器 + 伪造的 `window.webkit.messageHandlers` 把页面事件转出来。
- **在网页里每一步打点回传服务器**：ws open / 进房 / 远端视频到了 / 首帧 / 页面可见性。手机上出了问题，一眼看出死在哪一步。

---

## 这一章的坑

### 3.1 网页从没挂进窗口 ✅
- **现象**：服务端显示进房成功、令牌有效、对方在推流，手机上的 `<video>` 永远不出画面；有一次连 JS 都跑到一半停了。前后十几次真打，一次都没动过。
- **根因**：`WKWebView` 是单例上的普通属性，不是 `@Published`。通话页先渲染，`onAppear` 才去建网页 → `UIViewRepresentable` 第一次拿到 `nil`，之后没人通知它 → **网页从没进视图层级**。WebKit 会挂起不在窗口里的页面：网络照走，播放器不开播。
- **修法**：网页改成 `@Published`，作为参数传给 representable；挂上时打一条「window=true + 尺寸」日志。
- **教训**：在加打点之前，我们猜了一整天。

### 3.2 加了缓存版本号，页面 404 ✅
- **根因**：给脚本加了 `?v=1`，服务器拿**带 query 的** `req.url` 去查文件 → 永远找不到。画面空白，额度照扣。
- **修法**：先 `split("?")[0]`。加版本号那天要在真 URL 上 curl 一遍。
- 反过来也是坑：脚本用了长缓存，**改了 JS 不换版本号 = 手机上还是旧的**。

### 3.3 空闲超时比剩余额度长，开场 422 ✅
- `interaction_idle_timeout=180`，本月只剩 162 秒 → 拒绝。改成 `min(180, 剩余)`。

### 3.4 关场定时器没取消，第二句画面没了 ✅
- 上一句说完挂了「30 秒后关」，下一轮 `warm()` 看场子开着就 return，没续旧定时器，2 秒后关场。场子开着时 warm 要续期。

### 3.5 动完立刻变照片，不连贯 🟡
- 垫图和数字人源图不是同一张。换成同一张，淡入淡出拉到 0.9 秒。
- 这样好了一半：数字人一动，手和头就离开了原图的位置，切回照片还是有一下「定住」。真正缓解的是少断（3.9）+ 垫一段数字人自己的循环（3.12）。没完全解决。

### 3.6 「说完了」事件不带编号，永远不关场 ✅
- 开始事件带句子编号，结束事件不带。按编号判断「说完了」→ 永远对不上。

### 3.7 其他 📖/✅
- 只对嘴型的直通模式也必须填一个 TTS voice id，不填 422。
- 在 async 上下文里调 `evaluateJavaScript("…")` 会被解析成 throws 重载，要显式写 `completionHandler: nil`。
- 中文和英文用同一个声线，中文明显不像 —— 实时档的台词偏英文。
- 别用 `window.stop` 这种浏览器自带函数名当自己的函数。

### 3.8 还没验的 🟡
- 真实新帧检测之后，嘴型与本地声音是否仍需微调提前量（见坑 3.13）。
- 通话缩小再回来，网页能不能重新挂上。

### 3.9 按轮断开，越省越亏（大雷）：现象 ✅ 日志对过，修法 🟡 还没真机跑
- **现象**：为了省额度，每轮 ta 说完 2.5 秒就关场、你下一句再开。一周后对账：用掉的比预想多一截。
- **根因**：两笔账我们只算了一笔。
  - 每开一场，开场要 3~5 秒，而**计费从开场请求发出那一刻就开始**。
  - 每关一场，后台还要多记约 10 秒尾巴（我们按她后台对账推出来的，没拿到官方说法）。
  - 而开场是在你说完话那一刻触发的，ta 思考的时间本来就连着。日志里关场到下一次开场只隔 **1~4 秒**——为了省这一两秒，每次多交约 14 秒。
- **修法**：说完后一分钟没人开口才关。我们这一周白交的大约 7 次 × 14 秒 ≈ 一分半，免费档一个月才 10 分钟。
- **教训**：省额度之前先把「开一次要多少钱」量出来。只要重开的固定成本大于两轮之间的空隙，断就是亏的。

### 3.10 并发被拒，被记成「本月没额度」：服务端 ✅，app 端 🟡
- **现象**：三四轮之后 app 说本月额度用完，其实还剩一大半。
- **根因**：按轮断开时 warm → park → warm 两秒内连发，第一个开场请求还没回来，第二个就到了 → 服务返回 `429 code 30006 workspace concurrency limit`（同一工作区同时只能一场）。服务端换钥匙那段把所有非 422 的 4xx 都当「这把钥匙满了」记账；app 那边 429 一律结束整通的实时档，后面全程照片。
- **修法**：服务端开场排队（等前一个落地再开，再关掉旧场）；429 并发不记满；app 只在真没剩余秒数时放弃，并发失败这轮先出照片、下轮再试。
- 顺带：开场回包里的「剩余秒数」别先扣掉本场上限再报，不然开着场的时候菜单会显示「用完了」。

### 3.11 关场时先黑一下才变照片 🟡
- **根因**：关场时画面淡出（0.9 秒）和网页里的 stop 同时发生，stop 一下把视频清空，露出 `WKWebView` 的黑底。
- **修法**：stop 和关远端流延后 1 秒；下一次开场或挂断前先把延后的 stop 执行掉，免得旧 stop 杀掉新场。

### 3.12 多张源图换脸 + 垫底循环 🟡
- 开场时 `visual.source_images` 可以放多张，`default_source_image_id` 选开场那张；场中发 `session.update` 带 `source_image_id` 换，回 `session.update.done`（看 status）。实测一次约 3 秒、硬切，没有过渡。
- 我们按模型每轮标的〔表情〕挑图；开场请求把当前该用的脸带上，免得开场后再切一次。收到 `completed` 才改 app 里记的「现在是哪张脸」。
- 垫底循环：拿无头浏览器录数字人每张脸待机几秒，ffmpeg 交叉淡化成 6 秒无缝，放进 app 用 `AVQueuePlayer + AVPlayerLooper` 静音循环。
- 循环接缝黑一帧：①重新编码去掉 B 帧（`-bf 0 -g 30`）；②looper 的 timeRange 截掉最后一帧；③换脸时新 layer 等 `isReadyForDisplay` 再撤旧的；④素材从 `NSDataAsset` 写到 Caches 时文件名带字节数，免得读到旧素材。
- 用户的反馈值得记一句：有一张「手不会乱动」的静态照片，她反而更喜欢。默认那张我们就不垫循环，直接是照片。

### 3.13 声音说完了，数字人才开始动 🟡
- **现象**：本地 TTS 已经整句播完，数字人的新画面才到手机；看起来嘴型永远慢一拍。
- **根因**：`response.render.started` 只说明数字人服务开始渲染。RTC 传输和手机 `<video>` 解码还要时间，用它当「画面已开始」会过早播放声音。固定等 250ms 也不可靠，网络每次都不一样。
- **修法**：
  - 发送这一句前，先从 `<video>` 抽一小块像素作为基线。
  - 收到 `render.started` 后，用 `requestVideoFrameCallback` 等手机实际显示的新帧；每帧缩到小画布，和基线比较像素变化。
  - 变化过阈值才回传「可以播」，app 这时才播放同一段本地 TTS。
  - 每一句各等各的。只有取消、插话和关场才递增一个纪元号，让所有旧的等帧回调一起失效；另设约 3 秒兜底，避免视频异常时整句永远无声。
  - 别用「新一句来了就 +1」的全局 token：上一句还没等到新帧就被作废，它永远报不出「可以播」，那句就哑了。我们第一版就是这么写的。
  - 改完网页记得重新打包时带 `--minify`（不压是 1.6MB，压了 1.1MB），再换 `?v=`（坑 3.2）。
- **验证状态**：网页脚本和服务已更新；还要真机录一段确认首个发声音节和嘴型同时起。
