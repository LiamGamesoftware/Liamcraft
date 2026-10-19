# Orca

Orca is a safety-first AI development assistant integrated into the Godot editor.

This directory is the complete installable Orca 1.3.0 addon for Godot 4.7.2.

## Install

1. Copy `addons/orca/` into your Godot project's `addons/` directory.
2. Open the project in Godot 4.7.2.
3. Enable **Orca** in **Project > Project Settings > Plugins**.
4. Open the Orca dock, select a provider, add an API key when required, and choose a model.

## Safety Model

- Plan mode is read-only.
- A Plan turn can ask once to switch to Work, but it waits for an explicit user decision and the switch does not approve a file change.
- Work mode can prepare changes, but every model-requested project change requires explicit approval.
- File proposals use content hashes, validation, stale-state checks, and guarded revert data.
- Project access, tool output, network inactivity, and Orca-owned game processes are bounded.
- Root project instructions and skill catalog metadata are request-scoped guidance; skill bodies load only through the read-only `read_project_skill` tool.
- Godot API reflection, focused GDScript function reads, and serialized dependency discovery are read-only in Plan and Work.
- Provider failures after complete tool rounds are collapsed into sanitized recovery checkpoints, allowing the conversation to continue without replaying prior actions.

Always review proposed changes and use source control. Orca does not replace code review, backups, or project testing.

## Image Attachments

- Choose a vision-capable model, click the image icon, and use Browse or drop PNG/JPEG/WebP still images into Orca's separate attachment window. Up to four images can be attached per message.
- Paste copied screenshot/image pixels into the input with Ctrl/Cmd+V or context-menu Paste. Existing project images can also be dragged from Godot's FileSystem dock.
- Thumbnails float above the input with Remove and larger-preview actions; submitted images restore with conversation history.
- **Drop desktop files into the attachment window, not the main editor.** Godot imports desktop files dropped on its main window/dock into the selected project folder.
- Image capability is model/endpoint-specific. Unconfirmed profiles offer an explicit setting under Provider; vision support does not enable Agent tools.
- Source images are bounded to 10 MiB and 16 megapixels, resized to at most 2048 pixels per side, and normalized to at most 1 MiB each. Documents, PDFs, animation, and automatic screenshots are not supported.

## Providers And Data

Orca supports OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, Local OpenAI-compatible, and custom OpenAI-compatible endpoints through its current Chat Completions transport. Editable profiles start in Chat mode and require a successful project-free compatibility probe plus separate explicit opt-in before Orca project tools are exposed.

Native Ollama and LM Studio discovery hides models identified as embeddings. The manual Model ID remains available for unusual or unclassified models.

Prompts, attached images, relevant editor context, and project content returned by Orca's tools may be sent to the selected provider. API credentials are saved through Godot Editor Settings, and project-scoped session history (including submitted images) is stored as plaintext JSON under Godot's `user://` storage. Images are removed with conversation deletion/retention; pending drafts are memory-only. Neither storage mechanism is an encrypted OS credential store.

If present, `res://AGENTS.md` and skill catalog metadata from `res://skills/<slug>/SKILL.md` are automatically sent as private request context. A skill body is sent only after an explicit tool call. Request-scoped guidance is not retained in resumable conversation history.

## Resources

- Website: https://www.aiorca.dev/
- Documentation: https://www.aiorca.dev/docs/
- Source and releases: https://github.com/cold-atom/Orca
- Issues: https://github.com/cold-atom/Orca/issues
- Ideas and feature requests: https://github.com/cold-atom/Orca/discussions

## License

Orca source code is distributed under the MIT License included in this directory. Bundled third-party assets may carry their own license terms and attribution requirements.
