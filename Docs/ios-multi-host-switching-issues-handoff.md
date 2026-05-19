# ios-multi-host-switching 测试编译问题交接

日期：2026-05-19

## 需要处理的问题

`CodexMobileTests` 目前编译不过，导致完整 `xcodebuild test` 不能跑。请先修这些测试编译问题。

复现命令：

```sh
DEVELOPER_DIR=/Users/zhangjieying/Downloads/Xcode.app/Contents/Developer \
xcodebuild test \
  -project CodexMobile/CodexMobile.xcodeproj \
  -scheme CodexMobile \
  -configuration Debug \
  -destination 'id=FD3C93EE-0BE9-4188-B281-534E692D64FA' \
  -derivedDataPath /tmp/remodex-x86-sim-feature-dd \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  PHODEX_DEFAULT_RELAY_URL='ws://127.0.0.1:9000/relay'
```

已看到的编译错误：

```text
CodexMobileTests/TurnViewModelQueueTests.swift:261:23: error: errors thrown from here are not handled
CodexMobileTests/TurnViewModelQueueTests.swift:285:23: error: errors thrown from here are not handled
```

这两个测试方法是 `async`，但内部用了 `try XCTUnwrap(...)`。可以给方法加 `throws`，或改成非 throwing 的断言写法。

修掉上面后还会遇到：

```text
CodexMobileTests/CodexThreadRuntimeOverrideTests.swift:133:17:
'normalizeRuntimeSelectionsAfterModelsUpdate' is inaccessible due to 'fileprivate' protection level

CodexMobileTests/CodexThreadRuntimeOverrideTests.swift:150:22:
'normalizeRuntimeSelectionsAfterModelsUpdate' is inaccessible due to 'fileprivate' protection level
```

原因是测试直接调用了 `CodexService+RuntimeConfig.swift` 里 `private extension CodexService` 下的方法。需要调整测试入口，或者把被测方法改成测试可访问的 internal API。
