# PS Mirror for iOS

在 iPhone 上通过 Photoshop 的「远程连接」实时查看画布。
**不依赖自动发现**，手动填 IP + 密码直连，避开市面上那类 App「一直显示正在寻找 Photoshop」的问题。

## 为什么做这个

现有方案的问题：

| 方案 | 问题 |
|---|---|
| Adobe Preview CC | 2017 年 10 月已停 |
| CanvasView / Ps Play / Pixl Preview | 旧包在新 iOS 上失效；或卡在自动发现 |
| Mirror for Photoshop | 要求 PS 2023+，走 UXP 插件 |
| 浏览器方案 | 不是 App，需要电脑上常驻服务 |

本项目直接实现 PS 的私有协议，**PS 2017 ~ 2026 全版本通用**，不需要任何插件。

## 协议（已对 PS 2017 18.1.6 实测通过）

```
传输   裸 TCP 49494
加密   3DES-CBC + PKCS7
密钥   PBKDF2(密码, "Adobe Photoshop", 1000, 24B, SHA1)
IV     000000005d260000     ← 不是全零，很多第三方实现错在这
帧     [UInt32 BE: 4+len] [UInt32 BE: status] [cipher]
明文   [UInt32: ver=1] [UInt32: id] [UInt32: type] [payload]
类型   1=ERROR  2=JAVASCRIPT  3=PIXMAP  4=ICC  6=KEEPALIVE
```

取画面走 `type=2` 文本通道：在 PS 里执行 JS 把当前文档另存 JPEG、
读回、base64 编码后返回。PIXMAP 通道（`sendLayerThumbnailToNetworkClient`）
只把像素推给 Generator 的管道客户端，普通 TCP 连接收不到。

**实测延迟 2.3~2.7 秒/帧**（含 saveAs 写盘 + ExtendScript 编码），
瓶颈是 PS 侧固定开销，压不下去。

## PS 侧要求

1. `编辑 > 远程连接` → 勾选「启用远程连接」→ 设名称和密码 → **点确定**
2. 打开一个文档（没有打开的文档不会返回画面）
3. 电脑与手机在同一 WiFi
4. Windows 防火墙放行 Photoshop

## 构建

iOS 应用必须 macOS 编译。这里用 GitHub Actions：

```bash
# 推送到 main 自动触发，或手动运行 workflow
gh workflow run build.yml
```

产物：`PSMirror-unsigned.ipa`（**未签名**）

## 安装

未签名 ipa 需要用你自己的 Apple ID 签名：

1. 爱思助手 → 应用游戏 → 导入 IPA → 签名安装
2. 手机上「设置 > 通用 > VPN与设备管理」信任证书
3. **首次打开必须允许「本地网络」权限**，否则连不上 PS

免费 Apple ID 签名的有效期是 **7 天**，到期重签。

## 使用

1. 填电脑 IP（如 `192.168.3.4`）、端口 `49494`、PS 里设的密码
2. 点「连接」
3. 点「刷新画面」取一帧；打开「自动刷新」每 3 秒取一帧
4. 点画面可切换「适应屏幕 / 填满」

IP 和密码存在 UserDefaults，下次打开自动填好。

## 已知限制

- 2.3 秒/帧，做不到逐笔实时
- 画布宽度超过 1200px 时会自动缩到 1200px（保证速度）
- 不支持多文档切换（只读当前活动文档）
- 未签名 ipa，7 天需重签

## 目录

```
project.yml                 XcodeGen 工程描述
PSMirror/
  PSMirrorApp.swift         入口
  ContentView.swift         界面
  PSClient.swift            TCP + 分帧 + JS 执行
  PSCrypto.swift            3DES + PBKDF2
  Info.plist                含本地网络权限声明
.github/workflows/build.yml 云编译
```

## 许可

协议实现参考 Adobe `generator-core`（MIT）与 `theiviaxx/photoshopConnection`（MIT）。
本项目的加密参数以 Adobe 官方源码为准，未采用第三方实现中错误的 IV。
