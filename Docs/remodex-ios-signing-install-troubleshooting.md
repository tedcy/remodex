# Remodex iOS 真机安装签名排障记录

日期：2026-05-17

## 问题现象

昨天可以用命令行构建并安装 Remodex iOS App 到真机，今天相同流程失败。

失败点不是 Swift 代码编译，而是 iOS 真机签名：

- 工程默认 Bundle ID：`com.emanueledipietro.Remodex`
- 工程默认 Team：`HR24WHR326`
- 本机命令行 Xcode 当前没有这个 Team 的可用账号会话或 provisioning profile
- 因此 `xcodebuild` 无法为 `com.emanueledipietro.Remodex` 生成或选择描述文件

加 `-allowProvisioningUpdates` 后仍失败时，核心报错是没有对应 Team 的 Xcode Account；这说明问题在签名环境，不在本次多主机代码改动。

## 本机私有值

本文档只保留排障方法，不提交个人证书、团队标识、Bundle 标识、profile UUID、真机标识或本机路径。

本机实际值记录在：

```text
Docs/remodex-ios-local-signing.private.md
```

该文件已加入 `.gitignore`，只在本机保留。下文使用这些占位符：

- `<XCODE_DEVELOPER_DIR>`
- `<DEVICE_UDID>`
- `<DEVELOPMENT_TEAM>`
- `<PRODUCT_BUNDLE_IDENTIFIER>`
- `<SIGNING_CERTIFICATE>`
- `<PROVISIONING_PROFILE_NAME>`
- `<PROVISIONING_PROFILE_UUID>`
- `<DERIVED_APP_PATH>`

## 本机可用签名检查

本机能找到的 Apple Development 证书可用下面命令检查：

```sh
security find-identity -v -p codesigning
```

这次成功安装需要确认以下值互相匹配：

- 签名证书：`<SIGNING_CERTIFICATE>`
- 开发团队：`<DEVELOPMENT_TEAM>`
- Bundle 标识：`<PRODUCT_BUNDLE_IDENTIFIER>`
- 描述文件：`<PROVISIONING_PROFILE_NAME>`
- 描述文件 UUID：`<PROVISIONING_PROFILE_UUID>`
- 真机标识：`<DEVICE_UDID>`

注意：这个 profile 不在旧目录 `~/Library/MobileDevice/Provisioning Profiles`，而是在：

```sh
~/Library/Developer/Xcode/UserData/Provisioning Profiles/
```

可用以下命令检查本机 profile：

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  echo "PROFILE $f"
  security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - -
  echo
  security cms -D -i "$f" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - -
  echo
  security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - -
  echo
  security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw -o - -
  echo
done
```

检查 profile 是否包含当前手机：

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  echo "PROFILE $f"
  security cms -D -i "$f" 2>/dev/null | plutil -extract ProvisionedDevices xml1 -o - - | \
    rg '<DEVICE_UDID>|<string>'
done
```

## 为什么昨天能装今天不行

当前直接原因是命令行签名参数没有使用本机可用的侧载 profile，而是回到了上游默认的：

```text
com.emanueledipietro.Remodex + HR24WHR326
```

这套签名需要上游 Team `HR24WHR326` 的账号和 profile。本机当前没有，所以会失败。

昨天能装，是因为当时实际走的是本机已有的侧载签名：

```text
<PRODUCT_BUNDLE_IDENTIFIER> + <DEVELOPMENT_TEAM>
```

这套 profile 已包含当前 iPhone，所以只要在 `xcodebuild` 命令行覆盖 Team 和 Bundle ID，Xcode 就能自动选中已有 profile。

## 成功构建命令

不要手动传 `PROVISIONING_PROFILE_SPECIFIER`。它会被命令行全局应用到 Swift Package 资源 bundle 目标，导致大量包目标报：

```text
does not support provisioning profiles
```

正确做法是只覆盖 Team 和 Bundle ID，让 Xcode 自动选本机已有 profile：

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

本次验证结果：

```text
** BUILD SUCCEEDED **
```

签名结果可用下面命令确认：

```sh
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :CFBundleVersion' \
  <DERIVED_APP_PATH>/Info.plist

codesign -dv --verbose=4 \
  <DERIVED_APP_PATH> 2>&1 | \
  rg 'Identifier|TeamIdentifier|Authority'
```

本次输出关键值：

```text
<PRODUCT_BUNDLE_IDENTIFIER>
1.6
130
Identifier=<PRODUCT_BUNDLE_IDENTIFIER>
Authority=<SIGNING_CERTIFICATE>
TeamIdentifier=<DEVELOPMENT_TEAM>
```

## 成功安装和启动命令

安装：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
/usr/bin/xcrun devicectl device install app \
  --device <DEVICE_UDID> \
  <DERIVED_APP_PATH>
```

本次安装成功输出：

```text
App installed:
bundleID: <PRODUCT_BUNDLE_IDENTIFIER>
```

检查已安装 App：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
/usr/bin/xcrun devicectl device info apps \
  --device <DEVICE_UDID> \
  --filter "bundleIdentifier == '<PRODUCT_BUNDLE_IDENTIFIER>'" \
  --columns '*'
```

启动：

```sh
DEVELOPER_DIR=<XCODE_DEVELOPER_DIR> \
/usr/bin/xcrun devicectl device process launch \
  --device <DEVICE_UDID> \
  <PRODUCT_BUNDLE_IDENTIFIER>
```

本次启动成功输出：

```text
Launched application with <PRODUCT_BUNDLE_IDENTIFIER> bundle identifier.
```

## 下次再失败时的处理顺序

1. 先查 profile 是否还存在、是否过期、是否包含当前手机 UDID。
2. 再查 `security find-identity -v -p codesigning` 是否还有匹配证书。
3. 构建时覆盖 `DEVELOPMENT_TEAM=<DEVELOPMENT_TEAM>` 和 `PRODUCT_BUNDLE_IDENTIFIER=<PRODUCT_BUNDLE_IDENTIFIER>`。
4. 不要把个人 Team、Bundle ID 或 profile 名写回工程默认配置，除非明确只维护本机侧载分支。
5. 如果 profile 过期，先用 Xcode GUI 登录/刷新账号，或打开项目选择当前手机 Run 一次，让 Xcode 重新生成本机 profile。

## 注意事项

- `dist/` 下的 IPA 和 app bundle 是本机构建产物，不提交到 git。
- 这份文档记录的是本机侧载安装问题，不代表正式分发签名方案。
- 当前模拟器构建另有独立限制：本机是 x86_64，`GhosttyKit.xcframework` 缺 x86_64 simulator slice；这和真机签名失败不是同一个问题。
