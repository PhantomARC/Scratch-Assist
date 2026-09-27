extends Control

@onready var label1: Label = $BG/OUTDir/L1
@onready var folder_btn: Button = $BG/OUTDir/Folder
@onready var label2: Label = $BG/OUTDir/L2
@onready var file_btn: Button = $BG/OUTDir/File
@onready var go_btn: Button = $BG/OUTDir/GO
@onready var file_dialog: FileDialog = $FileD
@onready var folder_dialog: FileDialog = $FolderD

var selected_file: String = ""
var selected_folder: String = ""

const TARGET_FREQS: Array[float] = [20.0, 50.0, 65.0, 100.0, 125.0, 150.0, 200.0, 250.0, 400.0, 500.0, 700.0, 850.0, 1000.0, 1500.0, 2000.0, 2500.0, 3000.0, 4000.0, 5000.0, 6000.0, 8000.0, 10000.0, 15000.0, 20000.0]
const TARGET_FPS: int = 30

func _ready() -> void:
	file_dialog.use_native_dialog = true
	folder_dialog.use_native_dialog = true

	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = ["*.wav ; WAV Audio", "*.mp3 ; MP3 Audio", "*.ogg ; OGG Audio"]
	
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	
	folder_btn.pressed.connect(func(): folder_dialog.popup_centered())
	file_btn.pressed.connect(func(): file_dialog.popup_centered())
	go_btn.pressed.connect(_on_go_pressed)
	
	folder_dialog.dir_selected.connect(_on_folder_selected)
	file_dialog.file_selected.connect(_on_file_selected)
	
	_validate_inputs()

func _on_folder_selected(dir: String) -> void:
	selected_folder = dir
	label1.text = dir
	_validate_inputs()

func _on_file_selected(path: String) -> void:
	selected_file = path
	label2.text = path.get_file()
	_validate_inputs()

func _validate_inputs() -> void:
	go_btn.disabled = selected_file.is_empty() or selected_folder.is_empty()

func _on_go_pressed() -> void:
	go_btn.disabled = true
	var original_text = go_btn.text
	await _process_audio()
	go_btn.text = original_text
	go_btn.disabled = false

func _process_audio() -> void:
	var ext: String = selected_file.get_extension().to_lower()
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(selected_file)
	var audio_data: Dictionary
	
	if ext == "wav":
		go_btn.text = "Parsing WAV Instantly..."
		await get_tree().process_frame
		audio_data = _parse_wav_runtime(bytes)
	else:
		go_btn.text = "Recording MP3/OGG (Real-time)..."
		var stream: AudioStream
		if ext == "mp3":
			stream = AudioStreamMP3.new()
			stream.data = bytes
		elif ext == "ogg":
			stream = AudioStreamOggVorbis.load_from_buffer(bytes)
		
		var generated_wav = await _convert_compressed_to_wav(stream)
		if generated_wav:
			audio_data = {
				"data": generated_wav.data,
				"mix_rate": generated_wav.mix_rate,
				"channels": 2 if generated_wav.stereo else 1,
				"bps": 16 if generated_wav.format == AudioStreamWAV.FORMAT_16_BITS else 8,
				"is_float": false
			}
		
	if not audio_data.is_empty():
		go_btn.text = "Running FFT Analysis..."
		await _extract_and_write_frequencies(audio_data)
	else:
		push_error("Failed to parse or convert audio stream.")

func _convert_compressed_to_wav(stream: AudioStream) -> AudioStreamWAV:
	var bus_idx: int = AudioServer.bus_count
	AudioServer.add_bus(bus_idx)
	AudioServer.set_bus_name(bus_idx, "InternalConverter")
	AudioServer.set_bus_mute(bus_idx, true)
	
	var record_effect := AudioEffectRecord.new()
	AudioServer.add_bus_effect(bus_idx, record_effect)
	
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = "InternalConverter"
	player.pitch_scale = 1.0 
	add_child(player)
	
	record_effect.set_recording_active(true)
	player.play()
	
	await player.finished
	
	record_effect.set_recording_active(false)
	var generated_wav: AudioStreamWAV = record_effect.get_recording()
	
	player.queue_free()
	AudioServer.remove_bus(bus_idx)
	
	return generated_wav

func _parse_wav_runtime(data_bytes: PackedByteArray) -> Dictionary:
	var fmt_idx := -1
	for i in range(12, data_bytes.size() - 4):
		if data_bytes[i] == 102 and data_bytes[i+1] == 109 and data_bytes[i+2] == 116 and data_bytes[i+3] == 32: # "fmt "
			fmt_idx = i + 8
			break
			
	var data_idx := -1
	for i in range(12, data_bytes.size() - 4):
		if data_bytes[i] == 100 and data_bytes[i+1] == 97 and data_bytes[i+2] == 116 and data_bytes[i+3] == 97: # "data"
			data_idx = i + 8
			break
			
	if fmt_idx == -1 or data_idx == -1: 
		return {}
	
	var format_tag: int = data_bytes.decode_u16(fmt_idx)
	var channels: int = data_bytes.decode_u16(fmt_idx + 2)
	var sample_rate: int = data_bytes.decode_u32(fmt_idx + 4)
	var bps: int = data_bytes.decode_u16(fmt_idx + 14)
	
	var data_size: int = data_bytes.decode_u32(data_idx - 4)
	var raw_data = data_bytes.slice(data_idx, min(data_idx + data_size, data_bytes.size()))
	
	return {
		"data": raw_data,
		"mix_rate": sample_rate,
		"channels": channels,
		"bps": bps,
		"is_float": format_tag == 3
	}

func _extract_and_write_frequencies(audio: Dictionary) -> void:
	var raw_data: PackedByteArray = audio["data"]
	var mix_rate: int = audio["mix_rate"]
	var bps: int = audio["bps"]
	var num_channels: int = audio["channels"]
	var is_float: bool = audio["is_float"]
	
	var bytes_per_sample: int = bps / 8
	var bytes_per_frame: int = bytes_per_sample * num_channels
	var total_samples: int = raw_data.size() / bytes_per_frame
	
	var samples_per_entry: int = mix_rate / TARGET_FPS
	var window_size: int = 2048 
	
	var sample_idx: int = 0
	var processed_frames: int = 0
	var all_frames_output := PackedStringArray()
	
	while sample_idx < total_samples:
		var stereo_samples: Array[PackedFloat32Array] = _get_stereo_samples(raw_data, sample_idx, window_size, bytes_per_frame, bytes_per_sample, num_channels, is_float)
		var left_window: PackedFloat32Array = stereo_samples[0]
		var right_window: PackedFloat32Array = stereo_samples[1]
		var n: int = left_window.size()
		var frame_vals := PackedStringArray()
		
		for target in TARGET_FREQS:
			var k: float = (target * n) / float(mix_rate)
			var omega: float = (2.0 * PI * k) / n
			
			var l_r_sum: float = 0.0
			var l_i_sum: float = 0.0
			var r_r_sum: float = 0.0
			var r_i_sum: float = 0.0
			
			for i in range(n):
				var window_mult: float = 0.5 * (1.0 - cos(2.0 * PI * i / (n - 1)))
				var cos_val: float = cos(omega * i)
				var sin_val: float = sin(omega * i)
				
				var l_val: float = left_window[i] * window_mult
				l_r_sum += l_val * cos_val
				l_i_sum -= l_val * sin_val
				
				var r_val: float = right_window[i] * window_mult
				r_r_sum += r_val * cos_val
				r_i_sum -= r_val * sin_val
				
			var l_magnitude: float = sqrt(l_r_sum * l_r_sum + l_i_sum * l_i_sum) / n
			var l_dbfs: float = 20.0 * (log(max(l_magnitude, 0.0001)) / log(10.0))
			var l_scaled: int = clampi(int((l_dbfs + 80.0) * (100.0 / 80.0)), 0, 100)
			
			var r_magnitude: float = sqrt(r_r_sum * r_r_sum + r_i_sum * r_i_sum) / n
			var r_dbfs: float = 20.0 * (log(max(r_magnitude, 0.0001)) / log(10.0))
			var r_scaled: int = clampi(int((r_dbfs + 80.0) * (100.0 / 80.0)), 0, 100)
			
			frame_vals.append(str(l_scaled))
			frame_vals.append(str(r_scaled))
			
		all_frames_output.append("★".join(frame_vals) + "★")
		sample_idx += samples_per_entry
		processed_frames += 1
		
		if processed_frames % 300 == 0:
			go_btn.text = "Analyzed %d frames..." % processed_frames
			await get_tree().process_frame
		
	var file_name: String = selected_file.get_file().get_basename() + "_frequencies.txt"
	var out_path: String = selected_folder.path_join(file_name)
	var out_file := FileAccess.open(out_path, FileAccess.WRITE)
	
	out_file.store_string("\n".join(all_frames_output))
	out_file.close()
	
	print("Extraction Complete: Output saved to ", out_path, " | Total Frames: ", processed_frames)
	go_btn.text = "Done! Saved %d frames." % processed_frames
	await get_tree().create_timer(2.0).timeout

func _get_stereo_samples(data: PackedByteArray, start: int, count: int, frame_bytes: int, bytes_per_sample: int, num_channels: int, is_float: bool) -> Array[PackedFloat32Array]:
	var l_samples := PackedFloat32Array()
	var r_samples := PackedFloat32Array()
	l_samples.resize(count)
	r_samples.resize(count)
	
	for i in range(count):
		var pos: int = (start + i) * frame_bytes
		if pos + frame_bytes > data.size():
			l_samples[i] = 0.0
			r_samples[i] = 0.0
			continue
			
		l_samples[i] = _decode_sample(data, pos, bytes_per_sample, is_float)
		if num_channels == 2:
			r_samples[i] = _decode_sample(data, pos + bytes_per_sample, bytes_per_sample, is_float)
		else:
			r_samples[i] = l_samples[i]
			
	return [l_samples, r_samples]

func _decode_sample(data: PackedByteArray, pos: int, bytes_per_sample: int, is_float: bool) -> float:
	if bytes_per_sample == 2:
		return data.decode_s16(pos) / 32768.0
	elif bytes_per_sample == 3:
		var val: int = data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16)
		if val & 0x800000:
			val -= 0x1000000
		return val / 8388608.0
	elif bytes_per_sample == 4:
		if is_float:
			return data.decode_float(pos)
		else:
			return data.decode_s32(pos) / 2147483648.0
	else:
		return (data[pos] - 128) / 128.0
