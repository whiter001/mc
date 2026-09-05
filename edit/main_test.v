module main

// main_test.v — tests for the small set of pure helpers in main.v.
//
// main.v mostly hosts the Editor + its methods (which need a full
// Framebuffer to instantiate), but a couple of byte-count formatters are
// pure. Keeping them here keeps `cpulimit -l 200 -z -- ./build.sh test`
// honest without dragging in the rest of the editor.

fn test_clipboard_size_label_bytes() {
	// Below 1 KiB is still formatted in KiB with one decimal.
	assert clipboard_size_label(0) == '0 KiB'
	assert clipboard_size_label(512) == '0.5 KiB'
	assert clipboard_size_label(1023) == '0.9 KiB'
}

fn test_clipboard_size_label_kib_exact() {
	// Exact KiB values drop the decimal.
	assert clipboard_size_label(1024) == '1 KiB'
	assert clipboard_size_label(2 * 1024) == '2 KiB'
	assert clipboard_size_label(127 * 1024) == '127 KiB'
}

fn test_clipboard_size_label_kib_decimal() {
	// The function rounds to one decimal place via integer math:
	// dec = (size % 1024) * 10 / 1024. To get dec == 2 we need
	// (size % 1024) in [205, 307] (so 205*10/1024 = 2).
	assert clipboard_size_label(1024 + 256) == '1.2 KiB'
	// For dec == 5: (size % 1024) in [512, 614]. 512*10/1024 = 5.
	assert clipboard_size_label(1024 + 512) == '1.5 KiB'
	// 100 KiB + 512 bytes → kib=100, dec=512*10/1024=5 → "100.5 KiB".
	assert clipboard_size_label(100 * 1024 + 512) == '100.5 KiB'
}

fn test_clipboard_size_label_mib_exact() {
	// Exact MiB values drop the decimal.
	assert clipboard_size_label(1024 * 1024) == '1 MiB'
	assert clipboard_size_label(2 * 1024 * 1024) == '2 MiB'
	assert clipboard_size_label(8 * 1024 * 1024) == '8 MiB'
}

fn test_clipboard_size_label_mib_decimal() {
	// 1.5 MiB: mib=1, dec = 512*1024*10 / (1024*1024) = 5 → "1.5 MiB".
	assert clipboard_size_label(1024 * 1024 + 512 * 1024) == '1.5 MiB'
	// 2.3 MiB: mib=2, dec = 314573 * 10 / 1048576 = 3 (3145730/1048576=3).
	assert clipboard_size_label(2 * 1024 * 1024 + 314573) == '2.3 MiB'
}
