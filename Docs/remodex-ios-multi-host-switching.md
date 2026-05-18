# Remodex iOS 多主机切换记录

日期：2026-05-17

## 当前目标

在 iOS App 内支持保存并切换多台已信任的 Remodex 远端主机，方便同一台 iPhone 操控多台远程电脑。

当前实现是简单版：

- 可以保存多台已信任主机。
- 同一时间只连接一台主机。
- 用户在 `Settings -> Connection` 手动切换目标主机。
- 切换后自动发起 reconnect，不需要回首页再点一次。

## 用户入口

`Settings -> Connection` 现在包含：

- `New Connection`：打开现有 QR 扫描流程，用于配对新主机。
- `Saved Hosts`：展示所有已保存主机。
- `Switch`：切换到某台已保存主机，并立即自动重连。
- 垃圾桶按钮：删除保存的主机。离线主机也可以删除。
- `Reconnect`：当前未连接但有保存连接信息时，手动重连当前目标主机。
- `Forget Pair`：忘记当前 reconnect 候选。

## 行为说明

### 新连接

点 `New Connection` 后复用现有 QR 扫描界面。

扫描新主机 QR 后：

1. 停止当前自动重连或手动重连流程。
2. 保存 QR 内的 relay、session、Mac device id 和 Mac identity key。
3. 走 secure bootstrap handshake。
4. 配对成功后把这台主机写入 trusted host registry。

### 切换保存主机

点某个非当前主机的 `Switch` 后：

1. 如果当前正在连接或已连接，先断开当前连接。
2. 把目标主机写成当前 preferred trusted host。
3. 清空当前线程运行态，避免旧主机的线程列表继续展示。
4. 根据保存的 relay 信息自动发起 reconnect。
5. 连接成功后加载目标主机线程。

这个行为修复了早期版本的问题：早期 `Switch` 只切换展示目标，界面会停在 `offline`，用户还需要另外找到 reconnect 入口。

### 删除保存主机

每个 `Saved Hosts` 行右侧有垃圾桶按钮。

当前规则：

- 非当前主机可以直接删除。
- 当前主机在未连接状态下也可以删除。
- 当前主机连接中或已连接时，先断开再删除。

删除主机会同步清理对应 trusted host 记录；如果删的是当前 reconnect 候选，也会清理当前保存的 relay session。

## 已修改文件

- `CodexMobile/CodexMobile/Services/CodexService+TrustedPairPresentation.swift`
  - 生成 `trustedHostPresentations`。
  - 支持按最近使用时间排序，并把当前主机排在前面。
  - 支持 `selectTrustedHost(deviceId:)` 切换 preferred trusted host。

- `CodexMobile/CodexMobile/Services/CodexService+SecureTransport.swift`
  - 配对或 trusted reconnect 成功后更新 trusted host registry。
  - 保留每台主机的 relay URL、display name、最近解析 session 和最近使用时间。

- `CodexMobile/CodexMobile/Views/Settings/SettingsConnectionCard.swift`
  - 显示 `New Connection`。
  - 显示 `Saved Hosts`，即使只有一台保存主机也显示。
  - 支持 `Switch` 后自动重连。
  - 支持离线删除保存主机。
  - 离线但有 reconnect 候选时显示 `Reconnect`。

- `CodexMobile/CodexMobile/ContentView.swift`
  - 向 Settings 注入 `newConnectionAction`，复用 root 层 QR 扫描流程。
  - 向 Settings 注入 `reconnectAction`，复用现有 reconnect 流程。

- `CodexMobile/CodexMobileTests/CodexSecurePairingStateTests.swift`
  - 覆盖多主机 trusted registry 和切换相关状态。

## 相关提交

- `2cf8bbc 功能：支持 iOS 切换已信任主机`
- `4bb81f7 修复：显示并删除已保存主机`
- `75e3a24 修复：设置页添加新连接入口`
- `6cdf922 修复：切换保存主机后自动重连`

## 已知限制

- 当前不是并发多连接；同一时间只维护一个 active host。
- 切换主机时会清空当前线程列表，再由新主机重新加载。
- `Pair with Code` 仍依赖当前已知 relay 或默认 relay；全新 relay 的首次配对优先使用 QR。
- 如果保存主机的 relay URL 已失效，`Switch` 会进入 reconnect 失败状态，需要对该主机重新扫 QR。

## 验证命令

本机签名、设备和路径等私有值不写入本公开文档。实际值记录在
`Docs/remodex-ios-local-signing.private.md`，该文件已加入 `.gitignore`。

无签名通用构建：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
xcodebuild build \
  -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

本机真机侧载构建：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
xcodebuild build \
  -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  DEVELOPMENT_TEAM=<DEVELOPMENT_TEAM> \
  PRODUCT_BUNDLE_IDENTIFIER=<PRODUCT_BUNDLE_IDENTIFIER> \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development'
```

安装：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
/usr/bin/xcrun devicectl device install app \
  --device <DEVICE_UDID> \
  <DERIVED_APP_PATH>
```
