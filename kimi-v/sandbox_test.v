// sandbox_test.v — unit tests for resolve_within().
//
// We don't touch the real filesystem; resolve_within is a pure string
// operation. The tests use a fake `/sandbox` root (an absolute path that
// doesn't have to exist — abs_path only normalizes, it doesn't stat).
module main

// ---------- happy paths ----------------------------------------------------

fn test_resolve_within_accepts_root_itself() {
	res := resolve_within('/sandbox', '/sandbox') or {
		assert false, err.msg()
		return
	}
	assert res == '/sandbox'
}

fn test_resolve_within_accepts_relative_path() {
	// os.abs_path joins the process cwd when given a relative path. We
	// can't predict that here, so instead feed an already-absolute path
	// that the normalizer will pass through unchanged.
	res := resolve_within('/sandbox', '/sandbox/foo/bar.v') or {
		assert false, err.msg()
		return
	}
	assert res == '/sandbox/foo/bar.v'
}

fn test_resolve_within_accepts_dotdot_inside() {
	// /sandbox/a/../b is inside the sandbox.
	res := resolve_within('/sandbox', '/sandbox/a/../b') or {
		assert false, err.msg()
		return
	}
	assert res == '/sandbox/b'
}

fn test_resolve_within_accepts_dotted_components() {
	res := resolve_within('/sandbox', '/sandbox/./a/./b') or {
		assert false, err.msg()
		return
	}
	assert res == '/sandbox/a/b'
}

fn test_resolve_within_accepts_trailing_separator() {
	res := resolve_within('/sandbox/', '/sandbox/foo') or {
		assert false, err.msg()
		return
	}
	assert res == '/sandbox/foo'
}

// ---------- rejections -----------------------------------------------------

fn test_resolve_within_rejects_absolute_outside() {
	// /etc/passwd is unambiguously not under /sandbox.
	resolve_within('/sandbox', '/etc/passwd') or {
		assert err.msg().contains('outside sandbox')
		return
	}
	assert false, 'expected error, got success'
}

fn test_resolve_within_rejects_dotdot_escape() {
	// /sandbox/../escape escapes via parent traversal.
	resolve_within('/sandbox', '/sandbox/../escape') or {
		assert err.msg().contains('outside sandbox')
		return
	}
	assert false, 'expected error, got success'
}

fn test_resolve_within_rejects_partial_prefix() {
	// /sandbox-evil shares the prefix but is NOT under /sandbox.
	resolve_within('/sandbox', '/sandbox-evil/x') or {
		assert err.msg().contains('outside sandbox')
		return
	}
	assert false, 'expected error, got success'
}

fn test_resolve_within_rejects_empty_root() {
	resolve_within('', '/sandbox/foo') or {
		assert err.msg().contains('empty root')
		return
	}
	assert false, 'expected error, got success'
}

fn test_resolve_within_rejects_relative_root() {
	resolve_within('sandbox', '/sandbox/foo') or {
		assert err.msg().contains('root must be absolute')
		return
	}
	assert false, 'expected error, got success'
}
