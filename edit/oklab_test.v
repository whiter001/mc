module main

// oklab_test.v — tests for the V port of crates/edit/src/oklab.rs.
//
// Covers channel extraction, sRGB -> Oklab -> sRGB round-trip consistency
// (tolerance of ±1/255 per channel), and the alpha=0 / alpha=opaque
// boundaries of `oklab_blend`.

// assert_roundtrip checks that converting `color` to Oklab and back yields
// the same color within ±1/255 on every channel.
fn assert_roundtrip(color u32) {
	orig := StraightRgba{ value: color }
	back := orig.as_oklab().as_rgba()

	assert i32(back.red()) >= i32(orig.red()) - 1 && i32(back.red()) <= i32(orig.red()) + 1
	assert i32(back.green()) >= i32(orig.green()) - 1 && i32(back.green()) <= i32(orig.green()) + 1
	assert i32(back.blue()) >= i32(orig.blue()) - 1 && i32(back.blue()) <= i32(orig.blue()) + 1
	assert i32(back.alpha()) >= i32(orig.alpha()) - 1 && i32(back.alpha()) <= i32(orig.alpha()) + 1
}

fn test_oklab_channels() {
	// Port of the Rust `test_channels`.
	c := StraightRgba{ value: 0xaabbccdd }
	assert c.red() == 0xaa
	assert c.green() == 0xbb
	assert c.blue() == 0xcc
	assert c.alpha() == 0xdd
	assert c.to_rgba() == 0xaabbccdd
}

fn test_oklab_roundtrip() {
	// Most colors round-trip within ±1/255 per channel. Fully saturated green
	// is the one exception (see test_oklab_roundtrip_saturated below): that
	// drift is inherent to the reference's fast cube-root estimator and the
	// V port reproduces the Rust implementation in crates/edit/src/oklab.rs
	// bit-for-bit.
	for color in [u32(0x000000ff), 0xffffffff, 0xff0000ff, 0x0000ffff,
		0xbe2c21ff, 0x3fae3aff, 0x204dbeff, 0xbb54beff, 0x00a7b2ff, 0xbebebeff,
		0x808080ff, 0x123456ff, 0xabcdef7f, 0x00000000, 0x01020304] {
		assert_roundtrip(color)
	}
}

fn test_oklab_roundtrip_saturated() {
	// The Rust reference gives 0x00ff00ff -> 0x06fe01ff (dr=6 dg=-1 db=1),
	// which the V port matches exactly. We lock in that reference behavior.
	orig := StraightRgba{ value: 0x00ff00ff }
	back := orig.as_oklab().as_rgba()
	assert back.to_rgba() == 0x06fe01ff
	assert back.red() == 0x06
	assert back.green() == 0xfe
	assert back.blue() == 0x01
	assert back.alpha() == 0xff
}

fn test_oklab_blend_fully_transparent() {
	// A fully transparent `top` leaves the bottom color unchanged.
	bottom := StraightRgba{ value: 0x123456ff }
	res := bottom.oklab_blend(StraightRgba{ value: 0xabcdef00 })

	assert i32(res.red()) >= i32(bottom.red()) - 1 && i32(res.red()) <= i32(bottom.red()) + 1
	assert i32(res.green()) >= i32(bottom.green()) - 1 && i32(res.green()) <= i32(bottom.green()) + 1
	assert i32(res.blue()) >= i32(bottom.blue()) - 1 && i32(res.blue()) <= i32(bottom.blue()) + 1
	assert i32(res.alpha()) >= i32(bottom.alpha()) - 1 && i32(res.alpha()) <= i32(bottom.alpha()) + 1
}

fn test_oklab_blend_fully_opaque() {
	// A fully opaque `top` completely covers the bottom color.
	bottom := StraightRgba{ value: 0x123456ff }
	top := StraightRgba{ value: 0xabcdefff }
	res := bottom.oklab_blend(top)

	// With top_a = 1 the bottom contributes nothing, so the result is `top`.
	assert i32(res.red()) >= i32(top.red()) - 1 && i32(res.red()) <= i32(top.red()) + 1
	assert i32(res.green()) >= i32(top.green()) - 1 && i32(res.green()) <= i32(top.green()) + 1
	assert i32(res.blue()) >= i32(top.blue()) - 1 && i32(res.blue()) <= i32(top.blue()) + 1
	assert i32(res.alpha()) >= i32(top.alpha()) - 1 && i32(res.alpha()) <= i32(top.alpha()) + 1
}
