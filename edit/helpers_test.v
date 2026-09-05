module main

// helpers_test.v — coverage for the pure helpers in helpers.v
// (Point.compare, Size.as_rect, Rect is_empty / width / height /
// contains / intersect, coord_clamp, rect_one / two / three).
//
// Most of these are trivial wrappers around 2D geometry. Tests pin
// the boundary semantics so refactors stay safe: empty rectangles,
// inclusive/exclusive contains bounds, degenerate intersections.

fn test_coord_clamp_in_range() {
	assert coord_clamp(5, 0, 10) == 5
	assert coord_clamp(0, 0, 10) == 0
	assert coord_clamp(10, 0, 10) == 10
}

fn test_coord_clamp_below_and_above() {
	// Below the floor clamps up; above the ceiling clamps down.
	assert coord_clamp(-3, 0, 10) == 0
	assert coord_clamp(15, 0, 10) == 10
	// Negative ranges are allowed.
	assert coord_clamp(-100, -50, 50) == -50
	assert coord_clamp(100, -50, 50) == 50
}

fn test_coord_clamp_degenerate() {
	// lo == hi forces every value to that single point.
	assert coord_clamp(7, 5, 5) == 5
	assert coord_clamp(-1, 5, 5) == 5
}

fn test_point_compare_orders_by_y_then_x() {
	// y dominates x.
	a := Point{ x: 100, y: 1 }
	b := Point{ x: 0, y: 2 }
	c := Point{ x: 50, y: 2 }
	assert a.compare(b) == -1 // y=1 < y=2
	// Same y, smaller x sorts first.
	assert c.compare(b) == 1 // x=50 > x=0
	// Identical points compare equal.
	d := Point{ x: 5, y: 5 }
	e := Point{ x: 5, y: 5 }
	assert d.compare(e) == 0
}

fn test_size_as_rect_anchors_at_origin() {
	// The rect spans [0, 0) .. [width, height).
	r := Size{ width: 80, height: 24 }.as_rect()
	assert r.left == 0
	assert r.top == 0
	assert r.right == 80
	assert r.bottom == 24
}

fn test_rect_one_two_three_padding() {
	// rect_one applies one value to all four sides (CSS padding: a).
	r1 := rect_one(3)
	assert r1 == Rect{ left: 3, top: 3, right: 3, bottom: 3 }
	// rect_two applies top/bottom then left/right (CSS padding: a b).
	r2 := rect_two(1, 5)
	assert r2 == Rect{ left: 5, top: 1, right: 5, bottom: 1 }
	// rect_three applies top, left/right, bottom (CSS padding: a b c).
	r3 := rect_three(1, 2, 3)
	assert r3 == Rect{ left: 2, top: 1, right: 2, bottom: 3 }
}

fn test_rect_is_empty_inclusive_edges() {
	// Zero-area rects are empty (the right and bottom edges are
	// exclusive, so left == right is empty).
	assert Rect{ left: 0, top: 0, right: 0, bottom: 0 }.is_empty()
	assert Rect{ left: 0, top: 0, right: 5, bottom: 0 }.is_empty()
	assert Rect{ left: 5, top: 0, right: 5, bottom: 5 }.is_empty()
	// A non-empty rect.
	assert !Rect{ left: 0, top: 0, right: 5, bottom: 5 }.is_empty()
	// Inverted rect (right < left, etc.) is also empty.
	assert Rect{ left: 5, top: 5, right: 0, bottom: 0 }.is_empty()
}

fn test_rect_width_and_height() {
	r := Rect{ left: 2, top: 3, right: 10, bottom: 8 }
	assert r.width() == 8
	assert r.height() == 5
	// Width can be negative for inverted rects (callers should check
	// is_empty first; the function still returns the signed delta).
	assert Rect{ left: 10, top: 0, right: 2, bottom: 0 }.width() == -8
}

fn test_rect_contains_exclusive_right_and_bottom() {
	r := Rect{ left: 0, top: 0, right: 5, bottom: 5 }
	// Inside corners.
	assert r.contains(Point{ x: 0, y: 0 })
	assert r.contains(Point{ x: 4, y: 4 })
	// The right/bottom edges are exclusive.
	assert !r.contains(Point{ x: 5, y: 0 })
	assert !r.contains(Point{ x: 0, y: 5 })
	assert !r.contains(Point{ x: 5, y: 5 })
	// Outside.
	assert !r.contains(Point{ x: -1, y: 0 })
	assert !r.contains(Point{ x: 0, y: -1 })
	assert !r.contains(Point{ x: 6, y: 3 })
}

fn test_rect_intersect_normal_overlap() {
	a := Rect{ left: 0, top: 0, right: 10, bottom: 10 }
	b := Rect{ left: 5, top: 5, right: 15, bottom: 15 }
	assert a.intersect(b) == Rect{ left: 5, top: 5, right: 10, bottom: 10 }
	// Symmetric.
	assert b.intersect(a) == Rect{ left: 5, top: 5, right: 10, bottom: 10 }
}

fn test_rect_intersect_disjoint_clamps_to_degenerate() {
	// Two rects that don't overlap would give left > right or
	// top > bottom; intersect() clamps so callers always get a
	// non-inverted (though possibly empty) result.
	a := Rect{ left: 0, top: 0, right: 5, bottom: 5 }
	b := Rect{ left: 10, top: 10, right: 15, bottom: 15 }
	r := a.intersect(b)
	assert r.is_empty()
	// Both dimensions collapse to the max of the left/top edges.
	assert r.left == 10
	assert r.top == 10
	assert r.right == 10
	assert r.bottom == 10
}

fn test_rect_intersect_contained() {
	// The smaller rect is fully inside the larger one.
	outer := Rect{ left: 0, top: 0, right: 100, bottom: 100 }
	inner := Rect{ left: 25, top: 25, right: 75, bottom: 75 }
	assert outer.intersect(inner) == inner
	assert inner.intersect(outer) == inner
}
