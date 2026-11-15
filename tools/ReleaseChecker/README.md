# GeekAudio 驱动更新

运行 `bash tools/ReleaseChecker/build.sh NEW_OUTPUT_DIRECTORY` 构建 macOS 15+ 通用 App 和 ZIP。App 可在 Intel 或 Apple Silicon 上查询版本，驱动安装适用于 x86_64 macOS 15 或 26。

在同一驱动 Release 提供完整安装包、App ZIP、`driver-update.json` 和 64 字节的 `driver-update.json.sig`。App 下载并校验手动安装使用的同一份整包。旧版 App 请从正式版页面下载更新。

App 界面跟随 macOS 的首选语言，支持简体中文和英文。也可以在「系统设置 → 通用 → 语言与地区 → 应用程序」为它指定语言，重新打开后生效。

签名清单使用 `GeekAudio/NullMoth/install/v2`。顶层 `tag` 是 GitHub 发行标签，`macOS` 为支持的系统主版本列表，`package` 包含整包的 `name`、`sha256` 和字节数 `size`。归档包含 `pkgroot`，其中构建信息和驱动安装标记都要匹配发行标签。

```bash
xcrun swiftc -swift-version 6 tools/ReleaseChecker/{ReleaseFeed,InstallPlan,SignDriverManifest}.swift -o /tmp/sign-driver-manifest
/tmp/sign-driver-manifest /path/to/ed25519.key driver-update.json driver-update.json.sig
```

私钥使用 32 字节种子的 Base64 表示，离线保存。更新器内置 `driver-public-key.txt`，所有下载线路都通过同一签名校验。完整包发布前可用 `Installer.sh prepare <archive> <sha256> <tag> <new-output-directory>` 检查解压、清单和签名。[累计发布规则](../../docs/GEEKAUDIO-RELEASES.md)
