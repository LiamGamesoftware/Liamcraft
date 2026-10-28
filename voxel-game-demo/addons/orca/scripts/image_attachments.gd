@tool
extends RefCounted

const MAX_IMAGES := 4
const MAX_SOURCE_BYTES := 10 * 1024 * 1024
const MAX_PIXELS := 16 * 1024 * 1024
const MAX_SOURCE_EDGE := 8192
const MAX_EDGE := 2048
const MAX_IMAGE_BYTES := 1024 * 1024
const MAX_SESSION_IMAGES := 32
const MAX_SESSION_IMAGE_BYTES := 8 * 1024 * 1024
const MAX_REQUEST_BYTES := 16 * 1024 * 1024
const PNG_PREFIX := "data:image/png;base64,"


static func prepare_file(path: String) -> Dictionary:
	if path.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp"]:
		return _failure("Choose a PNG, JPEG, or WebP still image.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_SOURCE_BYTES:
		return _failure("The image could not be read or exceeds the 10 MiB file limit.")
	var bytes := file.get_buffer(file.get_length())
	var dimensions := _source_dimensions(bytes)
	if not _valid_dimensions(dimensions):
		return _failure("Invalid image header or image exceeds 8192 pixels per side / 16 megapixels. Animated images are not supported.")
	var image := Image.new()
	var error := ERR_FILE_UNRECOGNIZED
	if bytes.size() >= 24 and bytes[0] == 137:
		error = image.load_png_from_buffer(bytes)
	elif bytes.size() >= 3 and bytes[0] == 255:
		error = image.load_jpg_from_buffer(bytes)
	else:
		error = image.load_webp_from_buffer(bytes)
	if error != OK or image.get_size() != dimensions:
		return _failure("The selected image is damaged or unsupported.")
	return prepare_image(image, path.get_file())


static func prepare_image(source: Image, filename: String = "Image") -> Dictionary:
	if source == null or source.is_empty() or not _valid_dimensions(source.get_size()):
		return _failure("The image exceeds the supported dimensions.")
	var image := source.duplicate() as Image
	image.convert(Image.FORMAT_RGBA8)
	var largest := maxi(image.get_width(), image.get_height())
	var resized := largest > MAX_EDGE
	if resized:
		var ratio := float(MAX_EDGE) / largest
		image.resize(maxi(1, roundi(image.get_width() * ratio)), maxi(1, roundi(image.get_height() * ratio)), Image.INTERPOLATE_LANCZOS)
	var bytes := image.save_png_to_buffer()
	for attempt in range(4):
		if bytes.size() <= MAX_IMAGE_BYTES:
			break
		resized = true
		image.resize(maxi(1, image.get_width() * 3 / 4), maxi(1, image.get_height() * 3 / 4), Image.INTERPOLATE_LANCZOS)
		bytes = image.save_png_to_buffer()
	if bytes.is_empty() or bytes.size() > MAX_IMAGE_BYTES:
		return _failure("The image could not be prepared within the 1 MiB attachment limit.")
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	var attachment := {"id": context.finish().hex_encode(), "name": filename.get_file().left(128), "width": image.get_width(), "height": image.get_height(), "data": Marshalls.raw_to_base64(bytes), "resized": resized}
	return {"success": true, "image": attachment}


static func valid_record(raw) -> bool:
	if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("data")) != TYPE_STRING or typeof(raw.get("id")) != TYPE_STRING:
		return false
	var id: String = raw["id"]
	var data: String = raw["data"]
	if id.length() != 64 or not id.is_valid_hex_number(false) or data.is_empty() or data.length() > ceili(MAX_IMAGE_BYTES / 3.0) * 4 or data.length() % 4 != 0:
		return false
	var bytes := Marshalls.base64_to_raw(data)
	if bytes.is_empty() or bytes.size() > MAX_IMAGE_BYTES or Marshalls.raw_to_base64(bytes) != data:
		return false
	var dimensions := _source_dimensions(bytes)
	if dimensions.x > MAX_EDGE or dimensions.y > MAX_EDGE or dimensions.x <= 0 or dimensions.y <= 0:
		return false
	if typeof(raw.get("width")) not in [TYPE_INT, TYPE_FLOAT] or typeof(raw.get("height")) not in [TYPE_INT, TYPE_FLOAT] or float(raw["width"]) != dimensions.x or float(raw["height"]) != dimensions.y:
		return false
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	if context.finish().hex_encode() != id or bytes[0] != 137:
		return false
	var image := Image.new()
	return image.load_png_from_buffer(bytes) == OK and image.get_size() == dimensions


static func sanitize_record(raw) -> Dictionary:
	if not valid_record(raw):
		return {}
	return {"id": raw["id"], "name": str(raw.get("name", "Image")).get_file().left(128), "width": int(raw["width"]), "height": int(raw["height"]), "data": raw["data"], "resized": bool(raw.get("resized", false))}


static func validate_images(images: Array) -> String:
	if images.size() > MAX_IMAGES:
		return "Attach at most four images per message."
	for image in images:
		if not valid_record(image):
			return "An image attachment is invalid. Remove it and attach it again."
	return ""


static func texture(record: Dictionary) -> Texture2D:
	if not valid_record(record):
		return null
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw(record["data"])) != OK:
		return null
	return ImageTexture.create_from_image(image)


static func request_messages(messages: Array) -> Array:
	var result := messages.duplicate(true)
	for message in result:
		if typeof(message) != TYPE_DICTIONARY:
			continue
		var images: Array = message.get("images", [])
		message.erase("images")
		if images.is_empty():
			continue
		var parts: Array = [{"type": "text", "text": str(message.get("content", ""))}]
		for image in images:
			parts.append({"type": "image_url", "image_url": {"url": PNG_PREFIX + str(image["data"]), "detail": "auto"}})
		message["content"] = parts
	return result


static func image_token_reserve(record: Dictionary) -> int:
	# Conservative allowance, not a provider tokenizer. Never count base64 as text.
	return maxi(4096, ceili(float(record.get("width", MAX_EDGE)) / 32.0) * ceili(float(record.get("height", MAX_EDGE)) / 32.0) * 4)


static func _valid_dimensions(size: Vector2i) -> bool:
	return size.x > 0 and size.y > 0 and size.x <= MAX_SOURCE_EDGE and size.y <= MAX_SOURCE_EDGE and size.x * size.y <= MAX_PIXELS


static func _source_dimensions(bytes: PackedByteArray) -> Vector2i:
	if bytes.size() >= 33 and bytes.slice(0, 8) == PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]):
		# Bound chunk traversal and reject APNG before decoding.
		var cursor := 8
		var chunks := 0
		while cursor + 12 <= bytes.size():
			chunks += 1
			if chunks > 4096:
				return Vector2i.ZERO
			var length := _be32(bytes, cursor)
			var kind := bytes.slice(cursor + 4, cursor + 8).get_string_from_ascii()
			if kind == "acTL" or length > bytes.size() - cursor - 12:
				return Vector2i.ZERO
			cursor += length + 12
			if kind == "IEND":
				break
		return Vector2i(_be32(bytes, 16), _be32(bytes, 20)) if bytes.slice(12, 16).get_string_from_ascii() == "IHDR" else Vector2i.ZERO
	if bytes.size() >= 4 and bytes[0] == 255 and bytes[1] == 216:
		var cursor := 2
		while cursor + 4 <= mini(bytes.size(), 1024 * 1024):
			if bytes[cursor] != 255:
				return Vector2i.ZERO
			var marker := bytes[cursor + 1]
			if marker == 255:
				cursor += 1
				continue
			var length := bytes[cursor + 2] * 256 + bytes[cursor + 3]
			if length < 2 or cursor + length + 2 > bytes.size():
				return Vector2i.ZERO
			if marker in [192, 193, 194] and length >= 8:
				return Vector2i(bytes[cursor + 7] * 256 + bytes[cursor + 8], bytes[cursor + 5] * 256 + bytes[cursor + 6])
			cursor += length + 2
	if bytes.size() >= 30 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		var kind := bytes.slice(12, 16).get_string_from_ascii()
		if kind == "VP8X":
			if bytes[20] & 2:
				return Vector2i.ZERO
			return Vector2i(1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16), 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16))
		if kind == "VP8 " and bytes.slice(23, 26) == PackedByteArray([157, 1, 42]):
			return Vector2i((bytes[26] + (bytes[27] << 8)) & 16383, (bytes[28] + (bytes[29] << 8)) & 16383)
		if kind == "VP8L" and bytes[20] == 47:
			return Vector2i(1 + bytes[21] + ((bytes[22] & 63) << 8), 1 + (bytes[22] >> 6) + (bytes[23] << 2) + ((bytes[24] & 15) << 10))
	return Vector2i.ZERO


static func _be32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) + (bytes[offset + 1] << 16) + (bytes[offset + 2] << 8) + bytes[offset + 3]


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error": message}
