# 05 · 原生来电和灵动岛

ta 打给你时锁屏全屏响铃，横幅上是 ta 的照片和正在说的那句话；响铃时灵动岛上一张邀请卡。

基础链路（VoIP 推送 → 当场报来电 → 接听 → 自己配音频）和十一堵墙见
[ios-app-where-it-breaks / 02-calls](https://github.com/Cheiineeey/ios-app-where-it-breaks/tree/main/02-calls)。这一章只写那之后新撞的。

> ⚠️ 需要付费开发者账号（VoIP 推送）。

## 这一篇讲什么

1. [视频来电](#1-视频来电)
2. [横幅上放 ta 的照片](#2-横幅上放-ta-的照片)
3. [横幅上放 ta 正在说的话](#3-横幅上放-ta-正在说的话)
4. [灵动岛邀请卡的生命周期](#4-灵动岛邀请卡的生命周期)
5. [这一章的坑](#这一章的坑)

---

## 1. 视频来电

和语音来电同一条链，`CXCallUpdate.hasVideo = true`。推送 payload 里带 `kind: video` 和 `expires_at`。

## 2. 横幅上放 ta 的照片

系统拿 handle 去通讯录配人，配上了才用联系人照片。

```swift
config.supportedHandleTypes = [.generic, .emailAddress]   // 不声明，配人那条路根本不开
update.remoteHandle = CXHandle(type: .emailAddress, value: "<ta 的邮箱>")
// 响铃时不要设 localizedCallerName —— 它会盖掉联系人名字，你看不出到底配上没有
```

然后在通讯录建一张卡片：同一个邮箱，配上 ta 的照片。两边一字不差。

## 3. 横幅上放 ta 正在说的话

系统通话界面唯一能写字的地方是 `localizedCallerName`。接通后每说一句：

```swift
let u = CXCallUpdate()
u.localizedCallerName = sentence     // 只设这一项；没设的属性 = 不变
provider.reportCall(with: uuid, updated: u)
```

- 节流 1.2 秒，**但要留尾巴**：最后一句被拦掉的话，横幅会永远停在倒数第二句。
- 只放 ta 的话；轮到你说时写「在听 / 在想」，不然就成了回音。
- 单行，长了系统自己截断；做不成滚动字幕。
- 响铃和挂断都要重置，不然上一通的字幕会在下一通响铃时冒出来。

## 4. 灵动岛邀请卡的生命周期

邀请卡由服务端用 push-to-start 起。它要在这些时候消失：你接、你拒、过期没人管、拒了之后推送才到。

```
服务端 push-to-start（带 stale-date）+ VoIP（带 expires_at）
      │
      ▼
 手机上出卡 ── 你接 ──▶ 收掉同一通的全部卡，开通话
      │
      ├─── 你拒 ──▶ 收卡
      ├─── 到期 ──▶ 响铃自己挂未接 + 收卡
      └─── app 回前台 / 冷启动 ──▶ 扫一遍过期卡（留 20 秒宽限）
```

---

## 这一章的坑

### 5.1 横幅上没有头像 ✅
- **根因**：`CXHandle(type: .generic, …)` 永远配不上通讯录里的任何人。
- **📖 别换框架**：LiveCommunicationKit 里**根本没有头像 API**。我们把 SDK 的 swiftinterface 整份读了，只有一个模板角标图。
- 修法见第 2 节。

### 5.2 角标图一直是空的 ✅
- `UIImage(named: "AppIcon")` 读不到 appiconset，返回 `nil`，`if let` 静默跳过。单独放一张普通 imageset。它是模板图，只取轮廓。

### 5.3 邀请卡挂在岛上不走 🟡
四层，全是静默的：
1. **服务端用 push-to-start 起的卡，服务端收不回来**。没有这张卡自己的 update token，发不了 `end`。
2. 收卡写的是 `activity ?? activities.first` —— 只收一张。而同一台手机可能有新旧两个 push-to-start token，「推到 2 台」其实是同一台推了两次，**两张卡必剩一张**。
3. 收卡只挂在「你按了接 / 拒」那一下。过期没人按、推送晚到都没人收。
4. 响铃到期也没人挂。

修法见第 4 节：收掉同类型的**全部**、到期自己挂、回前台扫、过期卡点了只收卡不开通话。

### 5.4 `stale-date` 不会让卡消失 📖
- 它只是把卡标成过期样式。真消失靠 app 去 end。

### 5.5 扫卡把正在响的卡收掉了 🟡（预判）
- VoIP 冷启动时，回前台的扫描可能跑在「登记这一通」之前，那时还不知道哪张该留。**留 20 秒宽限**。
- 刚收养的卡状态可能还没更新，扫的时候按 activity id 排除，不能只看状态字段。

### 5.6 一个 push-to-start token ≠ 一台设备 ✅
- 服务端记的 token 数不等于设备数。推之前去重，或者干脆让 app 每次上报时替换旧的。
