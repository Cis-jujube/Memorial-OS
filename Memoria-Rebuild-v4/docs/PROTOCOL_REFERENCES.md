# 本轮实现参考

接口适配参考各服务的官方文档；URL 可用性和模型支持可能变化，当前账户能力必须单独连接测试。

- OpenAI 工具调用：https://developers.openai.com/api/docs/guides/function-calling
- DeepSeek JSON 输出：https://api-docs.deepseek.com/guides/json_mode/
- DeepSeek 当前模型名称：https://api-docs.deepseek.com/updates/
- DeepSeek 思考强度参数：https://api-docs.deepseek.com/guides/thinking_mode/
- Claude 客户端工具定义：https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools
- Gemini 原生函数调用：https://ai.google.dev/gemini-api/docs/function-calling
- Grok 工具调用：https://docs.x.ai/developers/tools/function-calling
- GLM / Z.AI：https://docs.z.ai/guides/capabilities/function-calling
- TypeSafe Jev 请求与响应：https://docs.typesafe.ai/introduction/quickstart
- Jev 模型与语言支持：https://docs.typesafe.ai/models
- Open-Meteo：https://open-meteo.com/en/docs
- Brave Search：https://api-dashboard.search.brave.com/documentation

系统 API 和 SwiftUI 宏的本机兼容性以安装的 Swift 6.4 SDK 接口与实际编译为依据。Jev 本地技能不是新 App 的运行依赖，没有读取本机 Jev 凭据。
