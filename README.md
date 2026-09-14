# GymLog

一款 AI 加持、支持语音控制的 iOS 训练记录应用：开口说出训练安排即可生成和修改计划，训练后由 AI 给出评价与建议。同时支持力量训练、CrossFit WOD、学员档案与历史分析，基于 SwiftUI + SwiftData 构建。

**源码发行版，不附带 API Key、托管云端服务或任何真实学员数据。** 日常记录、历史分析及热量估算可在本机直接使用；AI 和语音功能需要自行配置 API。最低部署版本 iOS 17。

[English](README.en.md) · [构建与配置](docs/SETUP.md) · [架构](docs/ARCHITECTURE.md) · [隐私](PRIVACY.md) · [贡献](CONTRIBUTING.md) · [安全](SECURITY.md) · [MIT 许可证](LICENSE)

## 功能

1. **计划与记录**：在手机上点选，或用自然语言说出安排，快速设定当天训练计划；训练中随手记录完成情况，并随时与历史成绩对比分析。
2. **力量训练与 CrossFit WOD 双支持**：既能记录常规力量训练，也能记录 CrossFit WOD，两类训练各有专门的记录方式。
   - 力量部分支持逐组设定负重与次数、超级组、递减组，并配有组间休息计时。
   - WOD 支持 AMRAP、For Time、EMOM 及间歇训练，内置对应倒计时；切到后台时仍会在每段结束时提醒，应用被关闭后重新打开也能恢复计时。
   - 分别记录 Rx、Scaled 或自定义版本，以及完成、超时（Time Cap）或中途停止等结果状态。
   - 只有动作、数量、负重、时限和计分方式完全一致的处方才会比较成绩，个人最佳（PR）不会因改过的训练而失真。
   - 成绩可生成简洁摘要（如“AMRAP 12:00 · 5 轮 + 12 次 · Scaled”），便于分享给教练或队友。
3. **自定义记录项目**：动作可自行新建，按需要选择记录方式（次数、时间、距离、轮数）及负重形式（绝对重量、单边、弹力带、器械档位、助力等）。
4. **教练与学员协同**：双方各自记录，通过互传文件交换训练计划与历史结果，无需手工重录。
5. **数据导入导出**：过往训练可从 Excel 文件导入（[格式说明](docs/EXCEL_FORMAT.md)）；已保存的训练可导出为标准 CSV，完整数据可通过备份文件备份和恢复。从相册选择 InBody 体测报告图片后，由本机识别并录入。
6. **动作库与模板**：内置 240 个中英双语动作，可将常用动作组合保存为训练模板，快速开展训练计划。
7. **热量估算**：根据活动类别和训练记录估算运动热量消耗。
8. **AI 评价与建议**：由人工智能对训练内容给出评价和改进建议。

除 AI 和语音外，其余功能均可在本机使用；AI 和语音功能需要自行配置 API。

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
