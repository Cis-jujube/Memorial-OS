# Memorial-OS

Memoria 的独立 macOS 重建版：先记录、就地确认，再用可追溯的记忆查询资料与安排活动。

当前源码位于 [`Memoria-Rebuild-v4`](Memoria-Rebuild-v4/)。使用 SwiftUI、Swift Package Manager 与系统框架，无第三方依赖。

## 构建与启动

```sh
cd Memoria-Rebuild-v4
./scripts/build-and-run.sh
```

脚本在本机生成 `dist/MemoriaRebuild.app` 并打开。要求 macOS 与 Swift 开发工具链；开发包采用本地 ad hoc 签名，未公证。

```sh
./scripts/test.sh
```

## 使用与实现状态

- [使用说明、配置和数据位置](Memoria-Rebuild-v4/README.md)
- [功能完成状态与验证边界](Memoria-Rebuild-v4/IMPLEMENTATION_STATUS.md)
- [产品取舍](Memoria-Rebuild-v4/DECISIONS.md)

目前已完成本地记录、人物、记忆确认与纠正、带来源查询、手动行程及备份恢复。六家模型和 Jev 的接入代码已实现，但真实服务兼容性与效果需配置用户自己的凭据后验证。未完成项在实现状态中单独列出。

本次视觉采用两档字号、纯文字操作、暖红橘渐变和米白背景，提供较大的输入区域与尊重系统减少动态效果设置的交互反馈。

仓库不包含用户记录、API Key、本机构建缓存或 App 二进制。构建和测试的原始日志只保留在开发机器；仓库保留验证结论与可重跑的测试源码。
