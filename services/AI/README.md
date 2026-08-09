# 🧠 AI

The **model layer** — the servers that run language models, and the interface you talk to them through.

This is one of three categories that split what people loosely call "AI", along a single line: **do you use a model, use an agent, or build agent systems?**

| Category | Question it answers |
|---|---|
| **AI** (here) | *Run a model, and chat with it.* |
| [AI-Agents](../AI-Agents/) | *An agent does work for me.* |
| [Multi-Agent](../Multi-Agent/) | *I build what the agents do.* |

---

## 📋 What's here

**Providers** — they run models and serve them over an API:

| | Notes |
|---|---|
| 🚧 [**Ollama**](ollama/) | The easiest. Pull a model by name and it's ready. The default choice, and every consumer supports it natively. |
| 🚧 [**llama.cpp**](llama-cpp/) | The engine underneath much of this space, served directly. Leanest and most tunable; you name a HuggingFace repo and a quantization rather than a friendly model name. |
| 🚧 [**LocalAI**](localai/) | Broadest: 35+ backends covering not just text but **speech-to-text, text-to-speech and image generation** in one server. That breadth is its real value. |

**Interface:**

| | Notes |
|---|---|
| 🚧 [**Open WebUI**](open-webui/) | A polished chat interface. Talks to any provider above — **or** straight to OpenAI/Anthropic with an API key. |

---

## 📌 Things worth knowing

**Every provider here speaks the OpenAI-compatible `/v1` API**, so any interface or agent in DockHub can talk to any of them. But they are **compatible, not equivalent** — `llama-server` serves **one** model at a time, while Ollama holds several and switches between them. Point a chat UI at llama.cpp and you'll see a single model, which can look broken if you expected a list.

**Run one provider, not several.** They all load models into the same GPU memory, and the model files themselves are many gigabytes each.

**A local provider is optional.** Every interface and agent in DockHub also accepts a cloud API key — so you can use this category, skip it entirely, or mix both.

---

← Back to [all services](../README.md)
