# Remodex iOS 本地侧载版交接

日期：2026-05-16

## 当前目标

把开源 Remodex iOS App 编译成可以在本机连接的 iPhone 上使用的本地侧载版，并适配个人开发者账号签名。当前安装到手机上的版本额外启用了本地 Pro 权限，用于跳过应用内的 5 次免费消息限制和 Pro 购买弹窗。

## 当前设备和签名信息

以下值按本机环境填写，不在文档中记录个人设备、证书或账号标识：

- Xcode：`<XCODE_APP>`
- `DEVELOPER_DIR`：`<XCODE_APP>/Contents/Developer`
- 设备 UDID：`<DEVICE_UDID>`
- Team ID：`<DEVELOPMENT_TEAM>`
- 签名证书：`Apple Development`
- Bundle ID：`<PRODUCT_BUNDLE_IDENTIFIER>`
- App 版本：`1.6 (130)`

## 已修改内容

### 1. 拆分时间线视图以通过 SwiftUI 类型检查

文件：

- `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelineView.swift`

说明：

- 原来的 SwiftUI `body` 表达式过大，真机构建时编译器在类型检查阶段失败。
- 已把大表达式拆成多个更小的视图属性和辅助方法。
- 这项改动是编译稳定性改动，不改变业务逻辑。

### 2. 适配个人开发者账号签名安装

文件：

- `CodexMobile/CodexMobile.xcodeproj/project.pbxproj`
- `CodexMobile/BuildSupport/PersonalTeam.entitlements`

说明：

- iPhone 真机签名使用 `BuildSupport/PersonalTeam.entitlements`。
- 该 entitlements 文件为空，用于避开个人 Team 不支持的 Push、Sign in with Apple、IAP 等能力。
- 移除了主 App Frameworks 阶段里显式链接的 `StoreKit.framework`。
- 这项改动只为本地个人账号侧载安装服务。

### 3. 启用本地侧载版 Pro 权限

文件：

- `CodexMobile/CodexMobile/Services/Payments/SubscriptionService.swift`

说明：

- 新增 `localProAccessEnabled = true`。
- `hasAppAccess` 始终通过。
- `hasFreeSendAccess` 始终通过。
- `consumeFreeSendAttemptIfNeeded()` 在本地 Pro 模式下直接返回，不再消耗 5 次免费消息次数。
- RevenueCat 刷新用户信息后，也不会把本地 Pro 状态覆盖回 Free。
- 这是本地开发/侧载行为，不代表 Apple 或 RevenueCat 线上订阅状态。

## SwiftPM 依赖处理

`fwcd/tree-sitter-kotlin` 远端解析不稳定时，可以使用本地浅克隆镜像：

- 本地镜像：`<TREE_SITTER_KOTLIN_MIRROR>`
- SwiftPM mirrors 配置：`~/Library/org.swift.swiftpm/configuration/mirrors.json`

镜像映射了：

- `https://github.com/fwcd/tree-sitter-kotlin`
- `https://github.com/fwcd/tree-sitter-kotlin.git`

到：

- `file://<TREE_SITTER_KOTLIN_MIRROR>`

## 编译命令

```sh
env DEVELOPER_DIR=<XCODE_APP>/Contents/Developer \
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 \
xcodebuild -project CodexMobile/CodexMobile.xcodeproj -scheme CodexMobile \
-configuration Debug -destination 'id=<DEVICE_UDID>' \
DEVELOPMENT_TEAM=<DEVELOPMENT_TEAM> PRODUCT_BUNDLE_IDENTIFIER=<PRODUCT_BUNDLE_IDENTIFIER> \
CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' APS_ENVIRONMENT= \
-allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

## 安装和启动命令

```sh
DEVELOPER_DIR=<XCODE_APP>/Contents/Developer \
xcrun devicectl device install app --device <DEVICE_UDID> \
<DERIVED_DATA>/CodexMobile/Build/Products/Debug-iphoneos/CodexMobile.app
```

```sh
DEVELOPER_DIR=<XCODE_APP>/Contents/Developer \
xcrun devicectl device process launch --device <DEVICE_UDID> \
<PRODUCT_BUNDLE_IDENTIFIER>
```

## 本地产物

当前生成过的本地 IPA：

- `dist/Remodex-1.6-local-pro-signed-personal.ipa`
- `dist/Remodex-1.6-signed-personal.ipa`
- `dist/Remodex-1.6-unsigned.ipa`

这些 IPA 是本机签名/构建产物，不建议提交到 git。需要时可以重新打包：

```sh
rm -rf dist/Remodex-1.6-local-pro-signed-personal.ipa dist/Remodex-local-pro-signed
mkdir -p dist/Remodex-local-pro-signed/Payload
ditto <DERIVED_DATA>/CodexMobile/Build/Products/Debug-iphoneos/CodexMobile.app \
dist/Remodex-local-pro-signed/Payload/CodexMobile.app
cd dist/Remodex-local-pro-signed
zip -qry ../Remodex-1.6-local-pro-signed-personal.ipa Payload
```

## 注意事项

- 这是本地侧载版，不是 App Store 或 TestFlight 分发版。
- 个人开发者账号签名存在描述文件/证书有效期限制，失效后需要重新编译安装。
- 由于本地签名去掉了个人 Team 不支持的能力，应用内购买、Push、Sign in with Apple 等线上能力不应按正式版预期验证。
- 如果要恢复官方订阅逻辑，优先 revert “启用本地侧载版 Pro 权限”对应的 commit。
