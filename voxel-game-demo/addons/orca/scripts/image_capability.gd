@tool
extends RefCounted

const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
# Exact canonical DeepSeek model contracts, checked against its public Vision /
# Models & Pricing guides on 2026-10-12. Never infer vision from provider alone.
const DEEPSEEK_IMAGE_INPUT := {
	"deepseek-flash": true,
	"deepseek-v4-flash": true,
	"deepseek-v4-flash-vision-exp": true,
	"deepseek-v4-pro": false,
	"deepseek-chat": false,
	"deepseek-reasoner": false,
}


static func resolve(config: Dictionary) -> String:
	var provider_id := str(config.get("provider", ""))
	var provider = ProviderRegistry.get_provider(provider_id)
	var cache := Config.get_cached_provider_models(provider_id, provider.models_url(config), str(config.get("api_key", "")).strip_edges().sha256_text().left(16))
	for model in cache.get("models", []):
		if typeof(model) == TYPE_DICTIONARY and model.get("id") == config.get("model") and typeof(model.get("image_input")) == TYPE_BOOL:
			return "supported" if model["image_input"] else "unsupported"
	# Public metadata describes the canonical hosted model, not an arbitrary alias/server.
	var base := str(config.get("base_url", "")).trim_suffix("/")
	if base != str(provider.definition().get("base_url", "")).trim_suffix("/") or provider_id in ["custom", "ollama", "lmstudio", "local_openai"]:
		return _unknown_or_override(config)
	var metadata := ModelMetadata.resolve(str(config.get("model", "")), base)
	if typeof(metadata.get("image_input")) == TYPE_BOOL:
		return "supported" if metadata["image_input"] else "unsupported"
	var model_id := str(config.get("model", ""))
	if provider_id == "deepseek" and DEEPSEEK_IMAGE_INPUT.has(model_id):
		return "supported" if DEEPSEEK_IMAGE_INPUT[model_id] else "unsupported"
	return _unknown_or_override(config)


static func _unknown_or_override(config: Dictionary) -> String:
	var record = config.get("image_input_override", {})
	return "supported" if typeof(record) == TYPE_DICTIONARY and record.get("binding") == binding(config) and record.get("enabled") == true else "unknown"


static func binding(config: Dictionary) -> String:
	return JSON.stringify([str(config.get("provider", "")), str(config.get("base_url", "")).trim_suffix("/"), str(config.get("model", ""))]).sha256_text()
