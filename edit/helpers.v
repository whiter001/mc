module main

// Port of crates/edit/src/helpers.rs (microsoft/edit).
// Coordinate types and 2D geometry helpers used throughout the application.

pub const kilo = 1000
pub const mega = 1000 * 1000
pub const giga = 1000 * 1000 * 1000

pub const kibi = 1024
pub const mebi = 1024 * 1024
pub const gibi = 1024 * 1024 * 1024

// CoordType is the viewport coordinate type used throughout the application.
// The Rust original uses isize; this port fixes it to i32.
pub type CoordType = i32

// coord_type_safe_max avoids overflow issues when adding two coordinates:
// it only uses half the bits of CoordType (0x7FFF for i32).
pub const coord_type_safe_max = CoordType(0x7fff)

// coord_clamp clamps v into [lo, hi].
pub fn coord_clamp(v CoordType, lo CoordType, hi CoordType) CoordType {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Point is a 2D point. Uses CoordType.
pub struct Point {
pub mut:
	x CoordType
	y CoordType
}

// compare orders points by y first, then by x (same as Rust's Ord impl).
pub fn (p Point) compare(other Point) int {
	if p.y != other.y {
		return if p.y < other.y { -1 } else { 1 }
	}
	if p.x != other.x {
		return if p.x < other.x { -1 } else { 1 }
	}
	return 0
}

// Size is a 2D size. Uses CoordType.
pub struct Size {
pub mut:
	width  CoordType
	height CoordType
}

// as_rect returns the size as a rectangle anchored at (0, 0).
pub fn (s Size) as_rect() Rect {
	return Rect{
		left:   0
		top:    0
		right:  s.width
		bottom: s.height
	}
}

// Rect is a 2D rectangle. Uses CoordType.
pub struct Rect {
pub mut:
	left   CoordType
	top    CoordType
	right  CoordType
	bottom CoordType
}

// rect_one mimics CSS's `padding: a` which is `a a a a`.
pub fn rect_one(value CoordType) Rect {
	return Rect{
		left:   value
		top:    value
		right:  value
		bottom: value
	}
}

// rect_two mimics CSS's `padding: a b` which is `a b a b`,
// where `a` is top/bottom and `b` is left/right.
pub fn rect_two(top_bottom CoordType, left_right CoordType) Rect {
	return Rect{
		left:   left_right
		top:    top_bottom
		right:  left_right
		bottom: top_bottom
	}
}

// rect_three mimics CSS's `padding: a b c` which is `a b c b`,
// where `a` is top, `b` is left/right, and `c` is bottom.
pub fn rect_three(top CoordType, left_right CoordType, bottom CoordType) Rect {
	return Rect{
		left:   left_right
		top:    top
		right:  left_right
		bottom: bottom
	}
}

// is_empty returns true if the rectangle is empty.
pub fn (r Rect) is_empty() bool {
	return r.left >= r.right || r.top >= r.bottom
}

// width returns the width of the rectangle.
pub fn (r Rect) width() CoordType {
	return r.right - r.left
}

// height returns the height of the rectangle.
pub fn (r Rect) height() CoordType {
	return r.bottom - r.top
}

// contains checks if the rectangle contains the given point.
pub fn (r Rect) contains(point Point) bool {
	return point.x >= r.left && point.x < r.right && point.y >= r.top && point.y < r.bottom
}

// intersect intersects two rectangles.
pub fn (r Rect) intersect(rhs Rect) Rect {
	l := if r.left > rhs.left { r.left } else { rhs.left }
	t := if r.top > rhs.top { r.top } else { rhs.top }
	mut rr := if r.right < rhs.right { r.right } else { rhs.right }
	mut b := if r.bottom < rhs.bottom { r.bottom } else { rhs.bottom }

	// Ensure that the size is non-negative. This avoids bugs,
	// because some height/width is negative all of a sudden.
	if l > rr {
		rr = l
	}
	if t > b {
		b = t
	}

	return Rect{
		left:   l
		top:    t
		right:  rr
		bottom: b
	}
}
