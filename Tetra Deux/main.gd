extends Control

@onready var label1: Label = $BG/OUTDir/L1
@onready var folder_btn: Button = $BG/OUTDir/Folder
@onready var go_btn: Button = $BG/OUTDir/GO
@onready var folder_dialog: FileDialog = $FolderD

var input_path: String = ""

const CHUNK_WIDTH = 480
const CHUNK_HEIGHT = 360

func _ready() -> void:
	folder_dialog.use_native_dialog = true
	
	# Connect the folder button to open the dialog
	folder_btn.pressed.connect(func(): folder_dialog.popup_centered())
	
	# Connect the GO button
	go_btn.pressed.connect(_on_go_pressed)
	
	# Connect the folder dialog signal
	folder_dialog.dir_selected.connect(_on_folder_selected)

func _on_folder_selected(dir: String) -> void:
	input_path = dir
	# Update the label to show the selected input directory
	label1.text = dir

func _on_go_pressed() -> void:
	# Don't proceed if a folder hasn't been selected
	if input_path == "":
		push_warning("Please select a folder first.")
		return
		
	go_btn.disabled = true
	var original_text = go_btn.text
	go_btn.text = "Processing..."
	
	# Wait for one frame so the UI has time to update and disable the button 
	# before the heavy image processing freezes the main thread
	await get_tree().process_frame
	
	process_folder(input_path)
	
	go_btn.text = original_text
	go_btn.disabled = false


func process_folder(dir_path: String) -> void:
	var out_dir = dir_path.path_join("TETRADEUX")
	var dir = DirAccess.open(dir_path)
	
	if dir == null:
		push_error("Failed to open directory: ", dir_path)
		return
		
	# Create the new TETRADEUX folder if it doesn't exist
	if not DirAccess.dir_exists_absolute(out_dir):
		var err = DirAccess.make_dir_absolute(out_dir)
		if err != OK:
			push_error("Failed to create TETRADEUX folder.")
			return
			
	# Prepare a single results.txt file inside TETRADEUX for all dimensions
	var txt_path = out_dir.path_join("results.txt")
	var txt_file = FileAccess.open(txt_path, FileAccess.WRITE)
	
	if txt_file == null:
		push_error("Failed to create results.txt at: ", txt_path)
		return
		
	var valid_exts = ["png", "jpg", "jpeg", "webp"]
	var image_number = 0
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		# Process only files (exclude subfolders)
		if not dir.current_is_dir():
			var ext = file_name.get_extension().to_lower()
			if ext in valid_exts:
				var img_path = dir_path.path_join(file_name)
				process_and_split_image(img_path, out_dir, image_number, txt_file)
				image_number += 1
		file_name = dir.get_next()
		
	txt_file.close()
	print("Finished processing all images into TETRADEUX.")


func process_and_split_image(img_path: String, out_dir: String, img_num: int, txt_file: FileAccess) -> void:
	var img = Image.load_from_file(img_path)
	if img == null or img.is_empty():
		push_error("Failed to load image from: ", img_path)
		return
		
	# Convert to RGBA8 to ensure we have an alpha channel for transparent padding
	img.convert(Image.FORMAT_RGBA8)
	
	var img_width = img.get_width()
	var img_height = img.get_height()
	
	# Write width and height to the open text file on separate lines
	txt_file.store_line(str(img_width))
	txt_file.store_line(str(img_height))
	
	# Calculate how many chunks we need. ceil() ensures any partial chunk gets a full canvas
	var cols = max(1, ceil(float(img_width) / CHUNK_WIDTH))
	var rows = max(1, ceil(float(img_height) / CHUNK_HEIGHT))
	
	for x in range(cols):
		for y in range(rows):
			# Create a blank, transparent 480x360 chunk
			var chunk_img = Image.create(CHUNK_WIDTH, CHUNK_HEIGHT, false, Image.FORMAT_RGBA8)
			
			# Determine how much of the original image actually fits in this specific chunk
			var start_x = x * CHUNK_WIDTH
			var start_y = y * CHUNK_HEIGHT
			var actual_width = min(CHUNK_WIDTH, img_width - start_x)
			var actual_height = min(CHUNK_HEIGHT, img_height - start_y)
			
			var source_rect = Rect2i(start_x, start_y, actual_width, actual_height)
			
			# Copy the pixels from the original image to our new blank chunk
			chunk_img.blit_rect(img, source_rect, Vector2i(0, 0))
			
			# Name the chunk A-B-C.png (Image number - X coord - Y coord)
			var file_name = str(img_num) + "-" + str(x) + "-" + str(y) + ".png"
			var save_path = out_dir.path_join(file_name)
			
			var error = chunk_img.save_png(save_path)
			if error != OK:
				push_error("Failed to save chunk: ", save_path)
				
	print("Successfully sliced image ", img_num, " into ", cols * rows, " chunk(s).")
