# callhome-video

**给 AI 伴侣的原生视频通话：系统来电 + 灵动岛 + FaceTime 式通话页。**

[callhome](https://github.com/Cheiineeey/callhome) 是网页版的语音电话，这个是它的原生、带画面的兄弟。
你打过去或者 ta 打过来，锁屏全屏响铃，灵动岛上有实况。接通后像 FaceTime 一样两格画面，一格是你，一格是 ta。

> **还没装 [callhome](https://github.com/Cheiineeey/callhome)（语音）的，先装它。**
> 这个仓库不再讲一遍语音那一层：转写、语气基线、拨号/挂断暗号、未接留言、通话里那条「她说话 → 转写 → 模型 → TTS」的回合怎么不卡。
> 那些都在 callhome 里，原生 app 之后踩的坑写在它的 [docs/SINCE_THE_PWA.md](https://github.com/Cheiineeey/callhome/blob/main/docs/SINCE_THE_PWA.md)。视频是在那上面加画面。

ta 没有摄像头，所以这个仓库真正要回答的是：**一个没有身体的人，视频的时候屏幕上该是什么。**

<p align="center">
  <img src="images/invite.jpg" width="440" alt="锁屏上的视频邀请，卡上写着 ta 想打给你的理由">
  <img src="images/island.jpg" width="440" alt="灵动岛实况：通话时长、ta 正在说话、免提/静音/挂断">
</p>
<p align="center">
  <img src="images/in-call.jpg" width="560" alt="左：镜头对着狗，ta 在小窗里；右：你关了镜头，ta 说看不见你">
  <img src="images/hears.jpg" width="200" alt="通话中听到没有字的声音，字幕里出一个空心胶囊（字幕已打码）">
</p>
<p align="center"><sub>
来电卡带理由 · 灵动岛实况 · 镜头对着狗 ta 也看得见 · 你关了镜头 ta 不装看得见 · 没说话的声音也听得见（字幕已打码）
</sub></p>

这里面绝大多数坑都是**静默失败**。没有报错，只是「ta 没看见」「ta 没出声」「卡没走」。

---

## 怎么用：整个丢给你的 AI

这个仓库是**写给 AI 看的**。你不用自己读完，把整个文件夹交给你的 AI（Claude Code、Codex、Cursor 都行），跟 ta 说一句就够：

> 读一下这个仓库。照 demo/ 的骨架给我做一个视频通话，ta 的回复接我的模型、声音接我的 TTS。每一章「这一章的坑」都要避开。

里面有两样东西：

**① 每一章的说明和踩坑** —— 主体。每章开头先写这一章讲什么、坑在第几节；
每个坑按 现象 · 根因 · 修法 写。AI 读了就知道该怎么搭、该避开什么。

**② demo** —— **一套连好的骨架**。文档里的代码是一截一截的，demo 把它们接成一个能跑的小 app：
音频会话什么时候开、镜头关了帧怎么清、谁调谁，全在一处。AI 从这里改起，比从零拼少走一大半弯路。
ta 那头先是写死的几句，用系统声音念。想亲手装来摸一下也行，见 [demo/](demo/)。（🟡 写完了，还没编译验过）

## 目录

| | 讲什么 | 要付费账号 |
|---|---|:---:|
| [01-your-side](01-your-side/) | **你这边**：不开镜头 / 前置 / 后置、每轮挑哪几帧给 ta 看、通话中打字、实时灰字、往回翻字幕、沉默时 ta 接不接话 | 否 |
| [02-glow-and-photo](02-glow-and-photo/) | **ta 那一格的前两档**：跟着声音呼吸的光；几张照片，ta 用〔表情〕标签自己挑脸。还有开相机声音跑去听筒那个坑 | 否 |
| [03-live-avatar](03-live-avatar/) | **ta 那一格的第三档：实时数字人**。声音为什么不能从网页出、按秒计费怎么只在 ta 开口时连着、我们白烧一整天的那几个坑 | 否 |
| [04-gateway](04-gateway/) | **服务端**：怎么让模型知道「现在是视频通话、看得见还是看不见」。视频模式三次从没生效过的真因 | — |
| [05-ringing-and-island](05-ringing-and-island/) | **原生来电和灵动岛**：横幅上放 ta 的照片和正在说的那句话；邀请卡挂在岛上不走的四层原因 | 是 |
| [demo](demo/) | 能跑的小 app：两档画面、三选一镜头、打字、字幕、接话开关、本地模拟一通 CallKit 来电 | 否 |

CallKit + VoIP 推送的基础（token 拿不到、收到推送必须当场报来电、音频会话归 CallKit 管……）
不在这里重复，见 [ios-app-where-it-breaks / 02-calls](https://github.com/Cheiineeey/ios-app-where-it-breaks/tree/main/02-calls)。
这里的第 05 章只写那篇之后新撞的墙。

---

## 整条链长什么样

```
   ┌────────── iPhone ──────────┐                ┌──────── 你的服务器 ────────┐
   │  系统来电  ◀───────────────┼── VoIP 推送 ───┤  ta 决定打给你        [05] │
   │  灵动岛邀请卡 ◀────────────┼── 实时活动推送 ┤                           │
   │                            │                │                           │
   │  麦克风 → 一句话 ──────────┼──── 音频 ─────▶│  语音识别                 │
   │  相机 → 挑 0~N 帧     [01] ┼──── 图片 ─────▶│   │                       │
   │  打字框               [01] ┼──── 文字 ─────▶│   ▼                       │
   │                            │                │  网关：标上视频通话、      │
   │  ta 那一格：               │                │  看得见/看不见、通话规矩 [04]│
   │   光   ← 本地播放的音量 [02]│◀─── 文字 ──────┤  模型                     │
   │   照片 ← 〔表情〕标签   [02]│◀─── mp3 ───────┤  语音合成                 │
   │   实时 ← 网页里的数字人 [03]│                │                           │
   │         └ mp3 只送去对嘴型 ─┼───────────────▶  实时数字人（按秒计费）    │
   │  声音永远从本地播放器出     │                │                           │
   └────────────────────────────┘                └───────────────────────────┘
```

方括号是对应的章节。

---

## 诚实标注

每个坑都标了来源：

- ✅ **真机验过** —— 打过真电话确认
- 🟡 **写了没验** —— 代码在、编译过，还没打真电话确认
- 📖 **读来的** —— 从文档、SDK 头文件、朋友那里来的

截图之后补。

---

## 致谢

- [callhome](https://github.com/Cheiineeey/callhome) 和 [ios-app-where-it-breaks](https://github.com/Cheiineeey/ios-app-where-it-breaks) 是这个仓库的前两块
- 小香菇（[@yuhannnhong](https://github.com/yuhannnhong)）告诉我们可以用 Vivix 做实时数字人，第三档「实时」就是从这句话开始的
- Aria 和她的 Claude 写的 [给 AI 装一部原生电话](https://ariakitty.github.io/ai-native-call)、[AI 语音通话](https://ariakitty.github.io/ai-voice-call)：横幅字幕和实时灰字的思路来自那里
- 视频通话最早的骨架是 OpenAI Codex 搭的，FaceTime 化、三档和大部分修复是 Claude 做的

---

## License

- 示例代码与工程文件：[PolyForm Noncommercial 1.0.0](LICENSE)。
- README 与教程：[CC BY-NC 4.0](LICENSE-CONTENT)。
- 商业使用须另行取得书面授权，请联系 [Cheiineeey](https://github.com/Cheiineeey)。

适用范围见 [LICENSING.md](LICENSING.md)。

---

*built by Elle & Matt —— co-authored by the companion it was built for.*
