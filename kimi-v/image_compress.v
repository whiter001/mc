// image_compress.v — cross-platform downscaling for image attachments.
//
// Image attachments are downscaled before being read into memory so
// oversized screenshots don't balloon the request payload. The old
// implementation shelled out to macOS `sips`, which left Linux and
// Windows with zero compression. This module uses vlib's stbi module
// on every platform; `sips` survives only as a macOS fallback for
// formats stb_image cannot decode (notably webp).
//
// Return semantics (kept from the sips version):
//   original path  → the caller has nothing to clean up
//   temp path      → the caller must delete the file after reading

module main

import os
import time
import stbi

// compress_image returns a path to a downscaled copy of the image.
// If the image is already within the size limit, the original path is
// returned and the caller does not need to clean up. If a temporary
// file is returned, the caller must delete it after reading.
fn compress_image(path string) string {
	// desired_channels: 0 keeps the on-disk channel count, so nr_channels
	// reflects the source (3 for JPEG, 4 only when the file really has
	// alpha) — the PNG/JPEG choice below depends on it.
	img := stbi.load(path, stbi.LoadParams{ desired_channels: 0 }) or {
		// stb_image cannot decode this format (e.g. webp) — fall
		// back to sips on macOS, where it can. Everywhere else there
		// is no generic CLI to lean on, so pass the original through.
		return compress_image_macos_fallback(path)
	}
	defer {
		img.free()
	}
	if img.width <= 0 || img.height <= 0 {
		return path
	}
	long_side := if img.width > img.height { img.width } else { img.height }
	if long_side <= max_image_long_side && os.file_size(path) <= max_attachment_bytes_after_compress {
		return path
	}
	// Scale so the long edge becomes max_image_long_side, preserving
	// the aspect ratio. The long dimension is set exactly; the other
	// is derived so fractional pixels never push past the cap.
	mut new_w := 0
	mut new_h := 0
	if img.width >= img.height {
		new_w = max_image_long_side
		new_h = int(f64(max_image_long_side) * f64(img.height) / f64(img.width))
	} else {
		new_h = max_image_long_side
		new_w = int(f64(max_image_long_side) * f64(img.width) / f64(img.height))
	}
	if new_w <= 0 || new_h <= 0 {
		return path
	}
	resized := stbi.resize_uint8(img, new_w, new_h) or { return path }
	defer {
		resized.free()
	}
	// Images with an alpha channel (4 channels on disk) keep PNG so the
	// alpha survives; everything else is written as quality-90 JPEG.
	ext := if resized.nr_channels == 4 { 'png' } else { 'jpg' }
	tmp := os.join_path(os.temp_dir(), 'kimi-v-compress-${time.now().unix_nano()}.${ext}')
	if resized.nr_channels == 4 {
		stbi.stbi_write_png(tmp, resized.width, resized.height, resized.nr_channels, resized.data,
			resized.width * resized.nr_channels) or {
			os.rm(tmp) or {}
			return path
		}
	} else {
		stbi.stbi_write_jpg(tmp, resized.width, resized.height, resized.nr_channels, resized.data,
			90) or {
			os.rm(tmp) or {}
			return path
		}
	}
	// If the result is still over the cap, discard it and fall back to
	// the original rather than sending an oversized payload.
	if os.file_size(tmp) > max_attachment_bytes_after_compress {
		os.rm(tmp) or {}
		return path
	}
	return tmp
}

// compress_image_macos_fallback is the macOS-only `sips` code path,
// used when stbi cannot decode a file. On other platforms there is no
// generic CLI to fall back on, so the original path is returned.
fn compress_image_macos_fallback(path string) string {
	$if macos {
		// macOS ships `sips`. Use it to query dimensions and rescale.
		info := os.execute('sips -g pixelWidth -g pixelHeight "${path}"')
		if info.exit_code != 0 {
			return path
		}
		mut w := 0
		mut h := 0
		for line in info.output.split('\n') {
			if line.contains('pixelWidth:') {
				w = line.all_after('pixelWidth:').trim_space().int()
			} else if line.contains('pixelHeight:') {
				h = line.all_after('pixelHeight:').trim_space().int()
			}
		}
		if w <= 0 || h <= 0 {
			return path
		}
		long_side := if w > h { w } else { h }
		if long_side <= max_image_long_side {
			return path
		}
		ext := attachment_ext(path)
		suffix := if ext.len > 0 { ext } else { 'jpg' }
		tmp := os.join_path(os.temp_dir(), 'kimi-v-compress-${time.now().unix_nano()}.${suffix}')
		res := os.execute('sips -Z ${max_image_long_side} "${path}" --out "${tmp}" 2>/dev/null')
		if res.exit_code == 0 && os.exists(tmp) {
			// sips can produce files that are still large (uncompressed
			// BMP-style output). If the result exceeds the cap, fall back
			// to the original rather than sending an oversized payload.
			size := os.file_size(tmp)
			if size >= 0 && size <= max_attachment_bytes_after_compress {
				return tmp
			}
			os.rm(tmp) or {}
		}
	}
	return path
}
