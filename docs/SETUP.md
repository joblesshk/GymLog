# 构建与配置

## 本机记录和模拟器

安装 Xcode 和 XcodeGen；运行 `cd GymLog && xcodegen generate`。工程不会包含默认学员；正常启动后创建自己的档案。`Fixtures/sample_seed.json` 是测试样例，不导入普通应用的新安装。

`GymLog` 是应用，`GymLogKit` 是模型及逻辑框架。`GymLogKitTests` 运行非宿主逻辑测试，避免应用与测试同时构建 SwiftData 容器。`GymLogUITests` 通过 `-uiTesting` 使用内存数据，不能在个人手机上以该参数做数据保留验收。

## 真机签名

在 Xcode 的 Signing & Capabilities 中选择自己的 Team，并为应用及框架设置唯一标识，或通过 `project.yml` 的对应 target 设置。示例标识 `org.example.gymlog` 不代表可用于发行的应用身份。生成工程会覆盖在生成文件内做出的配置，长期改动应放回 `project.yml`；不要提交 Team ID、描述文件或证书。

签名覆盖也可以通过命令行传递：

```sh
xcodebuild -project GymLog/GymLog.xcodeproj -scheme GymLog \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  -derivedDataPath /tmp/gymlog-device-build -allowProvisioningUpdates build
```

环境变量由开发者在本机设置，不在仓库中保存。

## 自备云端服务

按照 backend 的 README 部署 Worker。将无密钥的 HTTPS 服务根地址传入构建设置：

```sh
xcodebuild -project GymLog/GymLog.xcodeproj -scheme GymLog \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  GYMLOG_RELAY_BASE_URL="https://YOUR_WORKER_HOST" build
```

在 Xcode 中运行或安装到真机时，把 `GymLog/project.yml` 里的 `GYMLOG_RELAY_BASE_URL` 改为自己的地址（例如 `https://gymlog-cloud-relay.<你的子域>.workers.dev`），再运行 `cd GymLog && xcodegen generate` 重新生成工程；直接在生成的工程里修改会在下次生成时被覆盖。

服务根地址通过应用 Info.plist 的 `GymLogRelayBaseURL` 读取。ASR 与文字理解路由由客户端添加。默认 `.invalid` 地址下不会宣称云端已配置，也不附带作者的服务或调用额度。

模型默认 `deepseek-flash`；若更换模型，需要同时检查 Worker allowlist、客户端请求字段、JSON 输出能力及测试。Provider Key 只放在 Worker secrets。语音和训练评价共用安装身份配额，服务限制及供应商计费由部署者承担。

## 权限

麦克风用于主动发起的云端语音；蓝牙用于心率广播设备；系统照片选择器用于选择体测报告图片（无需相册权限）；通知用于计时提示。OCR、Excel 解析在本机执行。云端数据路径见 PRIVACY.md。
