# GymLog

SwiftUI + SwiftData 的 iOS 训练记录应用，支持力量训练、CrossFit WOD、学员档案、历史分析及可选的云端语音与 AI 评价。

**源码发行版，不附带 API Key、托管云端服务或任何真实学员数据。** 云端功能需要自行部署并配置；日常记录、历史分析及热量估算可在本机使用。最低部署版本 iOS 17。

[English](README.en.md) · [构建与配置](docs/SETUP.md) · [架构](docs/ARCHITECTURE.md) · [隐私](PRIVACY.md) · [贡献](CONTRIBUTING.md) · [安全](SECURITY.md) · [MIT 许可证](LICENSE)

## 功能

- 训练计划与实际完成量分别记录，支持不同负重轮次、超级组、计时与距离单位。
- AMRAP、For Time、EMOM、间歇 WOD，独立的处方、结果、计时器和可比成绩分析。
- 学员档案、体测、历史查询、训练趋势、CSV 导出、备份恢复和训练文件互传。
- 本机 Excel 解析和体测照片 OCR；输入文件不包含在仓库中。
- 240 个内置双语动作，以及明确标注为合成示例的基础模板。
- 计划与已记录部分的活动热量估算；缺失数据不当作零，器械显示 cal 不等同于人体消耗。
- 可选 DeepSeek 训练评价，以及云端语音识别和计划编辑。需要自己的服务与供应商账户。
- 繁体中文 / English、浅色 / 深色界面。

## 快速开始

需要 macOS、Xcode、XcodeGen；本机发布检查使用 Xcode 27。`project.yml` 是工程配置来源，Xcode 工程文件按需生成。

```sh
brew install xcodegen
cd GymLog
xcodegen generate
open GymLog.xcodeproj
```

选择 iPhone 模拟器运行。命令行构建不需要开发者签名：

```sh
xcodebuild -project GymLog/GymLog.xcodeproj -scheme GymLog \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

在仓库根目录运行本地检查：

```sh
python3 scripts/check-repository.py
bash scripts/test-ios.sh
cd backend/worker-relay
npm ci
npm run check
```

`test-ios.sh` 自动选取一个可用 iPhone 模拟器；也可通过 `GYMLOG_SIMULATOR_ID` 指定。真机需要自己的 Apple 开发者团队和唯一 bundle identifier，参见[配置说明](docs/SETUP.md)。

## 云端功能

默认服务地址是不可解析的示例占位地址。部署 `backend/worker-relay` 后，通过 `GYMLOG_RELAY_BASE_URL` 构建设置指定自己的 HTTPS 地址。供应商密钥只使用 Worker secrets 注入，不能写进项目文件、客户端配置或提交历史。

示例 Worker 带有安装身份额度控制，但**安装身份不是账户或可信设备认证**。公开部署前须根据自己的使用范围补充准入、滥用防护与费用控制。[部署说明](backend/worker-relay/README.md)

## 数据与估算边界

仓库只保留合成测试数据和通用动作词汇。原始开发过程中的私人数据、个人部署配置、截图及 Git 历史不属于这个源码发行版。私有资料测试不包含在当前测试套件中，不沿用其测试数量或结论。

热量来自活动类别 MET 和软件时间假设，是粗略估算，不是个人实测。距离缺少配速、不明轮次不会强行换算；WOD 提供区块估算。AI 无法仅凭次数和负重检查姿势、诊断伤病或保证训练效果。[规则与出处](docs/TRAINING_RULES.md)

## 目录

```text
GymLog/Sources/          应用、模型、记录流程、分析、导入导出、语音与 AI
GymLog/GymLogTests/      合成数据与协议测试
GymLog/GymLogUITests/    页面交互测试
GymLog/Fixtures/        明确标注的合成样例
GymLog/Resources/       通用动作库、示例模板、应用资源
backend/worker-relay/   可自行部署的 Cloudflare Worker
scripts/                构建、测试及提交前检查
docs/                   配置、架构、规则、发布和测试说明
.github/                CI、依赖更新、Issue 与 PR 模板
```

## 项目说明

- [测试方法](docs/TESTING.md)与[发布流程](docs/RELEASING.md)
- [变更记录](CHANGELOG.md)与[后续方向](docs/ROADMAP.md)
- [第三方来源](THIRD_PARTY_NOTICES.md)与[行为规范](CODE_OF_CONDUCT.md)

代码按 MIT 许可证提供。上游数据页面、服务、商标及依赖保留各自权利，不因本仓库的 MIT 许可而改变。
