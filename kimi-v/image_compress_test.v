// image_compress_test.v — unit tests for compress_image.
//
// Test images are generated programmatically with stbi's write
// functions, so the suite needs no binary fixtures to keep in sync
// with the compressor.

module main

import os
import time
import stbi

// temp_img_path returns a unique path in the system temp dir for a
// test image. Callers are responsible for os.rm-ing the file.
fn temp_img_path(tag string) string {
	return os.join_path(os.temp_dir(), 'kimi-v-imgtest-${time.now().unix_nano()}-${tag}')
}

fn test_compress_image_downscales_oversized_jpg() {
	// A 4000x3000 RGB buffer written as JPEG. The long side (4000)
	// exceeds max_image_long_side, so compress_image must return a
	// temp file whose long side is exactly max_image_long_side.
	src := temp_img_path('big.jpg')
	defer {
		os.rm(src) or {}
	}
	w, h := 4000, 3000
	// A smooth gradient (not random noise) so the JPEG actually
	// compresses: an incompressible buffer would stay over the byte
	// cap after downscaling and trip the "return original" fallback.
	mut buf := []u8{len: w * h * 3}
	for y in 0 .. h {
		for x in 0 .. w {
			idx := (y * w + x) * 3
			buf[idx] = u8(x * 255 / w)
			buf[idx + 1] = u8(y * 255 / h)
			buf[idx + 2] = u8((x + y) * 255 / (w + h))
		}
	}
	stbi.stbi_write_jpg(src, w, h, 3, buf.data, 90) or { panic(err) }

	compressed := compress_image(src)
	assert compressed != src, 'oversized image must be downscaled to a temp file, got original back'
	defer {
		os.rm(compressed) or {}
	}
	img := stbi.load(compressed, stbi.LoadParams{}) or { panic(err) }
	defer {
		img.free()
	}
	long_side := if img.width > img.height { img.width } else { img.height }
	assert long_side == max_image_long_side, 'long side must be downscaled to ${max_image_long_side}, got ${img.width}x${img.height}'
	assert img.width == 2000 && img.height == 1500, 'aspect ratio must be preserved, got ${img.width}x${img.height}'
}

fn test_compress_image_returns_original_when_within_limits() {
	// An 800x600 PNG is under both caps (long side and byte size), so
	// compress_image must return the original path unchanged.
	src := temp_img_path('small.png')
	defer {
		os.rm(src) or {}
	}
	w, h := 800, 600
	mut buf := []u8{len: w * h * 4}
	for y in 0 .. h {
		for x in 0 .. w {
			idx := (y * w + x) * 4
			buf[idx] = u8(x * 255 / w)
			buf[idx + 1] = u8(y * 255 / h)
			buf[idx + 2] = 128
			buf[idx + 3] = 255
		}
	}
	stbi.stbi_write_png(src, w, h, 4, buf.data, w * 4) or { panic(err) }

	compressed := compress_image(src)
	assert compressed == src, 'small image must be returned unchanged, got temp path: ${compressed}'
}

fn test_compress_image_returns_original_for_non_image() {
	// A text file is not decodable by stbi. On macOS the sips fallback
	// also fails on it, and on other platforms there is no fallback at
	// all — the original path is returned either way.
	src := temp_img_path('note.txt')
	defer {
		os.rm(src) or {}
	}
	os.write_file(src, 'this is not an image') or { panic(err) }

	compressed := compress_image(src)
	assert compressed == src, 'non-image file must be returned unchanged, got temp path: ${compressed}'
}
