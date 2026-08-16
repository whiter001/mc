module main

// unicode_tables_test.v — unicode_tables.v 的对照测试。
//
// 期望值的推导方法：用 tools/rs_tables_to_v.py 的 parse_tables() 解析
// tables.rs，再用 Python 逐行复刻 Rust 函数（同样的级联查表 / 位解包 /
// 矩阵查询）算出期望值，见各断言注释。属性位布局（见 unicode-gen main.rs
// BitPacking，--extended --line-breaks）：bit 0-4 grapheme cluster break，
// bit 5 cluster break ext，bit 6-10 line break class，bit 11-13 字符宽度。

fn test_lookup_ascii_width_1() {
	// 模拟得 lookup('a') = 0x0d80：宽度字段 0x0d80 >> 11 = 1。
	props := ucd_grapheme_cluster_lookup(`a`)
	assert props == 0x0d80
	assert ucd_grapheme_cluster_character_width(props, 1) == 1
}

fn test_lookup_cjk_width_2() {
	// 模拟得 lookup('中') = 0x15c0：宽度字段 0x15c0 >> 11 = 2。
	props := ucd_grapheme_cluster_lookup(`中`)
	assert props == 0x15c0
	assert ucd_grapheme_cluster_character_width(props, 1) == 2
}

fn test_combining_mark_width_0_and_joins() {
	// 模拟得 lookup(U+0301 COMBINING ACUTE) = 0x0004：宽度 0，GCB = 4。
	props_comb := ucd_grapheme_cluster_lookup(rune(0x0301))
	assert props_comb == 0x0004
	assert ucd_grapheme_cluster_character_width(props_comb, 1) == 0
	// 'a' 后接组合符应 join（同一个 grapheme cluster）：
	// 模拟 joins(0, 0x0d80, 0x0004) = 0，未 done。
	props_a := ucd_grapheme_cluster_lookup(`a`)
	state := ucd_grapheme_cluster_joins(0, props_a, props_comb)
	assert !ucd_grapheme_cluster_joins_done(state)
}

fn test_plain_letters_do_not_join() {
	// 两个普通字母之间应断簇：模拟 joins(0, 0x0d80, 0x0d80) = 3，done。
	props_a := ucd_grapheme_cluster_lookup(`a`)
	props_b := ucd_grapheme_cluster_lookup(`b`)
	state := ucd_grapheme_cluster_joins(0, props_a, props_b)
	assert ucd_grapheme_cluster_joins_done(state)
}

fn test_emoji_zwj_sequence_joins() {
	// 女程序员 = U+1F469 U+200D U+1F4BB，三个码点应属于同一 cluster。
	// 模拟得：props 分别为 0x15ce / 0x000f / 0x15ce；
	// joins(0, woman, zwj) = 0（未 done），joins(0, zwj, laptop) = 0（未 done），
	// 之后再跟普通字母 'a' 时 joins(0, laptop, a) = 3（done，断簇）。
	props_woman := ucd_grapheme_cluster_lookup(rune(0x1F469))
	props_zwj := ucd_grapheme_cluster_lookup(rune(0x200D))
	props_laptop := ucd_grapheme_cluster_lookup(rune(0x1F4BB))
	assert props_woman == 0x15ce
	assert props_zwj == 0x000f
	assert props_laptop == 0x15ce

	mut state := ucd_grapheme_cluster_joins(0, props_woman, props_zwj)
	assert !ucd_grapheme_cluster_joins_done(state)
	state = ucd_grapheme_cluster_joins(state, props_zwj, props_laptop)
	assert !ucd_grapheme_cluster_joins_done(state)
	// cluster 结束后接普通字母必须断开。
	state = ucd_grapheme_cluster_joins(state, props_laptop, ucd_grapheme_cluster_lookup(`a`))
	assert ucd_grapheme_cluster_joins_done(state)
}

fn test_line_break_joins() {
	// 模拟得 'a'/'b' 的 line break class 都是 22（AL），两个字母之间不允许
	// 断行（joins = true）；'a' 与 '中'（class 23）之间允许断行（false）。
	props_a := ucd_grapheme_cluster_lookup(`a`)
	props_b := ucd_grapheme_cluster_lookup(`b`)
	props_cjk := ucd_grapheme_cluster_lookup(`中`)
	assert ucd_line_break_joins(props_a, props_b) == true
	assert ucd_line_break_joins(props_a, props_cjk) == false
}

fn test_special_properties() {
	// 这三个值在 tables.rs 里是字面常量，非零且与 Rust 一致。
	assert ucd_start_of_text_properties() == 0x603
	assert ucd_tab_properties() == 0x963
	assert ucd_linefeed_properties() == 0x802
	// 与查表结果一致：'\t' 和 '\n' 的 lookup 恰好等于这两个常量。
	assert ucd_grapheme_cluster_lookup(`\t`) == ucd_tab_properties()
	assert ucd_grapheme_cluster_lookup(`\n`) == ucd_linefeed_properties()
}
