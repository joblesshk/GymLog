# 构建与配置

## 本机记录和模拟器

安装 Xcode 和 XcodeGen；运行 `cd GymLog && xcodegen generate`。工程不会包含默认学员；正常启动后创建自己的档案。`Fixtures/sample_seed.json` 是测试样例，不导入普通应用的新安装。

`GymLog` 是应用，`GymLogKit` 是模型及逻辑框架。`GymLogKitTests` 运行非宿主逻辑测试，避免应用与测试同时构建 SwiftData 容器。`GymLogUITests` 通过 `-uiTesting` 使用内存数据，不能在个人手机上以该参数做数据保留验收。

## 真机签名

本地构建自动读取 `GymLog/Config/Build.xcconfig`，它在占位默认值之后可选加载同目录的 `Local.xcconfig`。Debug、Release、Xcode 直接运行及命令行构建共用此配置。首次配置可复制 `Local.example.xcconfig` 为 `Local.xcconfig`，填写自己的服务地址、应用/框架 Bundle ID 与签名 Team；覆盖安装时必须沿用手机已有应用身份。

`Local.xcconfig` 是本地工程的持久配置，不会随重新生成工程被覆盖。它被 Git 忽略：推送 GitHub 时不包含该文件，但不得为了清理发布内容而删除电脑上的配置。GitHub 检出使用安全占位默认值；示例文件不包含作者服务地址或签名身份。仓库检查也会拒绝被强制加入版本控制的本地配置。

```sh
xcodegen generate --spec GymLog/project.yml
xcodebuild -project GymLog/GymLog.xcodeproj -scheme GymLog \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/gymlog-device-build -allowProvisioningUpdates build
```

## 自备云端服务

按照 backend 的 README 部署 Worker，然后在 `GymLog/Config/Local.xcconfig` 设置无密钥的 HTTPS 服务根地址：

```text
GYMLOG_RELAY_BASE_URL = https:/$()/YOUR_WORKER_HOST
```

xcconfig 中直接写 `https://` 会把双斜线当作注释，所以使用空变量 `$()` 分隔；构建后的地址仍为正常 `https://`。也可使用命令行 `GYMLOG_RELAY_BASE_URL` 临时覆盖。不要再把真实配置写入生成工程或共享 `project.yml`；既有 `project.local.yml` 可以作为包含主工程的兼容入口，避免维护两份工程定义。

服务根地址通过应用 Info.plist 的 `GymLogRelayBaseURL` 读取。ASR 与文字理解路由由客户端添加。默认 `.invalid` 地址下不会宣称云端已配置，也不附带作者的服务或调用额度。Provider Key 继续只放在 Worker secrets，不嵌入应用。

模型默认 `deepseek-flash`；若更换模型，需要同时检查 Worker allowlist、客户端请求字段、JSON 输出能力及测试。Provider Key 只放在 Worker secrets。语音和训练评价共用安装身份配额，服务限制及供应商计费由部署者承担。

## 权限

麦克风用于主动发起的云端语音；蓝牙用于心率广播设备；系统照片选择器用于选择体测报告图片（无需相册权限）；通知用于计时提示。OCR、Excel 解析在本机执行。云端数据路径见 PRIVACY.md。
