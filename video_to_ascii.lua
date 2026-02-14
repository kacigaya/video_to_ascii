#!/usr/bin/env lua

local lfs = require("lfs")

local CONFIG = {
	ascii_chars = " .,:;i1tfLCG08@",
	output_width = 120,
	output_fps = 30,
	audio_bitrate = "128k",
	temp_dir = "temp_ascii",
	output_format = "mp4",
	font_name = "Courier",
	font_size = 10,
	annotate_offset = "+5+15",
	ascii_batch_size = 50,
	render_batch_size = 100,
	aspect_ratio_correction = 0.5,
}

-- Derive frames_dir from temp_dir to avoid path duplication
CONFIG.frames_dir = CONFIG.temp_dir .. "/frames"
CONFIG.cache_file = CONFIG.temp_dir .. "/.cache"

local VideoToASCII = {}
VideoToASCII.__index = VideoToASCII

--- Escape a string for safe use inside single-quoted shell arguments.
--- Handles filenames containing special characters (including single quotes).
local function ShellEscape(str)
	return "'" .. str:gsub("'", "'\\''") .. "'"
end

--- Execute a shell command and return success status and exit code.
local function SafeExecute(cmd)
	local ok, exit_type, code = os.execute(cmd)
	if ok then
		return true, 0
	end
	return false, code or -1
end

--- Execute a shell command, capture stdout, and return (output, success).
local function SafePopen(cmd)
	local handle = io.popen(cmd)
	if not handle then
		return nil, false
	end
	local result = handle:read("*a")
	handle:close()
	return result, true
end

function VideoToASCII:New(input_file, output_file)
	local instance = setmetatable({}, VideoToASCII)
	instance.input_file = input_file
	instance.output_file = output_file or "output_ascii.mp4"
	instance.video_info = {}
	return instance
end

function VideoToASCII:CreateTempDirs()
	os.execute("mkdir -p " .. ShellEscape(CONFIG.frames_dir))
end

function VideoToASCII:Cleanup()
	os.execute("rm -rf " .. ShellEscape(CONFIG.temp_dir))
end

function VideoToASCII:GetVideoInfo()
	local cmd = string.format(
		"ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=s=x:p=0 %s",
		ShellEscape(self.input_file)
	)

	local result, ok = SafePopen(cmd)
	if not ok or not result then
		print("Error: Failed to read video info with ffprobe")
		return false
	end

	local width, height, fps_str = result:match("(%d+)x(%d+)x([%d/]+)")

	local fps = CONFIG.output_fps
	if fps_str then
		local num, den = fps_str:match("(%d+)/(%d+)")
		if num and den and tonumber(den) ~= 0 then
			fps = math.floor(tonumber(num) / tonumber(den))
		end
	end

	self.video_info = {
		width = tonumber(width) or 1920,
		height = tonumber(height) or 1080,
		fps = fps,
	}

	self.video_info.output_height =
		math.floor(CONFIG.output_width * self.video_info.height / self.video_info.width * CONFIG.aspect_ratio_correction)

	print(string.format("Video: %dx%d @ %d fps", self.video_info.width, self.video_info.height, self.video_info.fps))
	print(string.format("ASCII output: %dx%d characters", CONFIG.output_width, self.video_info.output_height))
	return true
end

function VideoToASCII:DisplayProgressBar(current, total, status, width)
	width = width or 50
	local percent = math.floor((current / total) * 100)
	local completed = math.floor((current / total) * width)
	local remaining = width - completed
	local bar = string.rep("█", completed) .. string.rep("░", remaining)

	local status_text = status or ""
	if status_text ~= "" then
		status_text = " | " .. status_text
	end

	io.write(string.format("\r[%s] %d%% (%d/%d)%s", bar, percent, current, total, status_text))
	io.flush()

	if current >= total then
		print()
	end
end

function VideoToASCII:PixelToAscii(brightness)
	local index = math.floor(brightness * (#CONFIG.ascii_chars - 1)) + 1
	index = math.max(1, math.min(index, #CONFIG.ascii_chars))
	return CONFIG.ascii_chars:sub(index, index)
end

function VideoToASCII:ReadPngFast(filename)
	local cmd = string.format(
		"magick %s -resize %dx%d! -colorspace Gray -compress none pgm:- | tail -n +4",
		ShellEscape(filename),
		CONFIG.output_width,
		self.video_info.output_height
	)

	local data, ok = SafePopen(cmd)
	if not ok or not data then
		return {}
	end

	local pixels = {}
	local pixel_count = 0

	for byte_str in data:gmatch("%S+") do
		local value = tonumber(byte_str)
		if value then
			pixel_count = pixel_count + 1
			pixels[pixel_count] = value / 255.0
		end
	end

	return pixels
end

function VideoToASCII:FrameToAsciiFast(frame_path)
	local pixels = self:ReadPngFast(frame_path)
	local lines = {}
	local chars_per_line = CONFIG.output_width

	for row = 0, self.video_info.output_height - 1 do
		local line_chars = {}
		for col = 1, chars_per_line do
			local idx = row * chars_per_line + col
			local brightness = pixels[idx] or 0
			line_chars[col] = self:PixelToAscii(brightness)
		end
		lines[row + 1] = table.concat(line_chars)
	end

	return table.concat(lines, "\n")
end

function VideoToASCII:CheckCache()
	local cache = io.open(CONFIG.cache_file, "r")
	if not cache then
		return false
	end

	local cached_input = cache:read("*l")
	local cached_mtime = cache:read("*l")
	cache:close()

	if cached_input ~= self.input_file then
		return false
	end

	local attrs = lfs.attributes(self.input_file)
	if not attrs then
		return false
	end

	return tostring(attrs.modification) == cached_mtime
end

function VideoToASCII:SaveCache()
	local attrs = lfs.attributes(self.input_file)
	if not attrs then
		return
	end

	local cache = io.open(CONFIG.cache_file, "w")
	if cache then
		cache:write(self.input_file .. "\n")
		cache:write(tostring(attrs.modification) .. "\n")
		cache:close()
	end
end

function VideoToASCII:ExtractFrames()
	print("Checking frames...")

	local frame_files = {}
	for file in lfs.dir(CONFIG.frames_dir) do
		if file:match("^frame_%d+%.png$") then
			table.insert(frame_files, file)
		end
	end

	local existing_count = #frame_files

	if existing_count > 0 and self:CheckCache() then
		print(string.format("Using %d cached frames", existing_count))
		return existing_count
	end

	if existing_count > 0 then
		print("Input changed, regenerating frames...")
		os.execute("rm -f " .. ShellEscape(CONFIG.frames_dir) .. "/*.png " .. ShellEscape(CONFIG.frames_dir) .. "/*.txt")
	else
		print("Extracting frames...")
	end

	local cmd = string.format(
		"ffmpeg -i %s -vf 'fps=%d,scale=%d:%d' %s -hide_banner -loglevel warning",
		ShellEscape(self.input_file),
		CONFIG.output_fps,
		CONFIG.output_width,
		self.video_info.output_height,
		ShellEscape(CONFIG.frames_dir .. "/frame_%05d.png")
	)

	local ok, code = SafeExecute(cmd)
	if not ok then
		print(string.format("Error: Frame extraction failed (exit code %d)", code))
		return 0
	end

	local count = 0
	for file in lfs.dir(CONFIG.frames_dir) do
		if file:match("%.png$") then
			count = count + 1
		end
	end

	print(string.format("Frames extracted: %d", count))
	self:SaveCache()
	return count
end

function VideoToASCII:ProcessFramesBatch()
	print("Converting frames to ASCII...")

	local png_files = {}
	for file in lfs.dir(CONFIG.frames_dir) do
		if file:match("^frame_%d+%.png$") then
			table.insert(png_files, file)
		end
	end

	table.sort(png_files)

	if #png_files == 0 then
		print("No frames found")
		return 0
	end

	local txt_count = 0
	for file in lfs.dir(CONFIG.frames_dir) do
		if file:match("^frame_%d+%.txt$") then
			txt_count = txt_count + 1
		end
	end

	if txt_count == #png_files then
		print(string.format("All %d ASCII frames exist", txt_count))
		return txt_count
	end

	local batch_size = CONFIG.ascii_batch_size
	local processed = 0

	for i = 1, #png_files, batch_size do
		local batch_end = math.min(i + batch_size - 1, #png_files)

		for j = i, batch_end do
			local file = png_files[j]
			local txt_file = file:gsub("%.png$", ".txt")
			local txt_path = CONFIG.frames_dir .. "/" .. txt_file

			local exists = io.open(txt_path, "r")
			if exists then
				exists:close()
			else
				local frame_path = CONFIG.frames_dir .. "/" .. file
				local ascii_frame = self:FrameToAsciiFast(frame_path)

				local out = io.open(txt_path, "w")
				if out then
					out:write(ascii_frame)
					out:close()
				end

				processed = processed + 1
			end
		end

		self:DisplayProgressBar(batch_end, #png_files, "Converting to ASCII")
	end

	print(string.format("Converted %d new frames", processed))
	return #png_files
end

function VideoToASCII:ProcessAudio()
	print("Processing audio...")

	local audio_file = CONFIG.temp_dir .. "/audio.wav"
	local cmd = string.format(
		"ffmpeg -i %s -vn -acodec pcm_s16le %s -hide_banner -loglevel error -y",
		ShellEscape(self.input_file),
		ShellEscape(audio_file)
	)
	local ok = SafeExecute(cmd)
	if not ok then
		print("Warning: Audio extraction failed; output will have no audio")
		return nil
	end

	local processed_audio = CONFIG.temp_dir .. "/audio_processed.wav"
	cmd = string.format(
		"ffmpeg -i %s -af 'compand=attacks=0.3:decays=1.0:points=-70/-60|-60/-40|-40/-30|-20/-20' %s -hide_banner -loglevel error -y",
		ShellEscape(audio_file),
		ShellEscape(processed_audio)
	)
	ok = SafeExecute(cmd)
	if not ok then
		print("Warning: Audio compression failed; using raw audio")
		return audio_file
	end

	print("Audio processed")
	return processed_audio
end

function VideoToASCII:CreateAsciiVideoFast()
	print("Creating ASCII video...")

	local txt_files = {}
	for file in lfs.dir(CONFIG.frames_dir) do
		if file:match("^frame_%d+%.txt$") then
			table.insert(txt_files, file)
		end
	end

	table.sort(txt_files)

	if #txt_files == 0 then
		print("No ASCII frames found")
		return false
	end

	print(string.format("Rendering %d ASCII frames to images...", #txt_files))

	local batch_size = CONFIG.render_batch_size
	for i = 1, #txt_files, batch_size do
		local batch_end = math.min(i + batch_size - 1, #txt_files)

		for j = i, batch_end do
			local file = txt_files[j]
			local txt_path = CONFIG.frames_dir .. "/" .. file
			local png_path = txt_path:gsub("%.txt$", "_ascii.png")

			local cmd = string.format(
				"magick -size %dx%d xc:black -font %s -pointsize %d -fill white -annotate %s @%s %s 2>/dev/null",
				self.video_info.width,
				self.video_info.height,
				CONFIG.font_name,
				CONFIG.font_size,
				CONFIG.annotate_offset,
				ShellEscape(txt_path),
				ShellEscape(png_path)
			)
			os.execute(cmd)
		end

		self:DisplayProgressBar(batch_end, #txt_files, "Rendering ASCII frames")
	end

	print("Encoding video from images...")

	local cmd = string.format(
		"ffmpeg -framerate %d -pattern_type glob -i %s -c:v libx264 -preset ultrafast -pix_fmt yuv420p %s -hide_banner -loglevel error -y",
		CONFIG.output_fps,
		ShellEscape(CONFIG.frames_dir .. "/*_ascii.png"),
		ShellEscape(CONFIG.temp_dir .. "/video_temp.mp4")
	)
	local ok = SafeExecute(cmd)
	if not ok then
		print("Error: Video encoding failed")
		return false
	end

	print("Video created")
	return true
end

function VideoToASCII:CombineVideoAudio(audio_file)
	if not audio_file then
		-- No audio available; copy video as final output
		local cmd = string.format(
			"ffmpeg -i %s -c copy %s -hide_banner -loglevel error -y",
			ShellEscape(CONFIG.temp_dir .. "/video_temp.mp4"),
			ShellEscape(self.output_file)
		)
		SafeExecute(cmd)
		print(string.format("Output (no audio): %s", self.output_file))
		return
	end

	print("Combining video and audio...")

	local cmd = string.format(
		"ffmpeg -i %s -i %s -c:v copy -c:a aac -b:a %s -shortest %s -hide_banner -loglevel error -y",
		ShellEscape(CONFIG.temp_dir .. "/video_temp.mp4"),
		ShellEscape(audio_file),
		CONFIG.audio_bitrate,
		ShellEscape(self.output_file)
	)

	local ok = SafeExecute(cmd)
	if not ok then
		print("Error: Failed to combine video and audio")
		return
	end
	print(string.format("Output: %s", self.output_file))
end

function VideoToASCII:Convert()
	print("- Video to ASCII Converter -")
	print(string.format("Input: %s", self.input_file))

	local file = io.open(self.input_file, "r")
	if not file then
		print("Error: File not found - " .. self.input_file)
		return false
	end
	file:close()

	self:CreateTempDirs()

	local info_ok = self:GetVideoInfo()
	if not info_ok then
		self:Cleanup()
		return false
	end

	local frame_count = self:ExtractFrames()
	if frame_count == 0 then
		print("Error: No frames were extracted")
		self:Cleanup()
		return false
	end

	self:ProcessFramesBatch()

	local audio_file = self:ProcessAudio()

	local video_ok = self:CreateAsciiVideoFast()
	if not video_ok then
		self:Cleanup()
		return false
	end

	self:CombineVideoAudio(audio_file)
	self:Cleanup()

	print("Completed")
	return true
end

local function Main(args)
	if not args or #args < 1 then
		print("Usage: lua video_to_ascii.lua <input_video> [output_video]")
		return
	end

	local input_file = args[1]
	local output_file = args[2]

	local converter = VideoToASCII:New(input_file, output_file)
	converter:Convert()
end

Main(arg)
