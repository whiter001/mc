#!/usr/bin/env python3
"""rs_tables_to_v.py — 把 microsoft/edit 生成的 unicode tables.rs 机械转换为 V。

用法：
    python3 tools/rs_tables_to_v.py <tables.rs 路径> > unicode_tables.v

解析 tables.rs 中的静态数组（STAGE0..3 三级查找表、GRAPHEME_JOIN_RULES、
LINE_BREAK_JOIN_RULES），生成 module main 的 V 代码。8 个 ucd_* 函数按
crates/edit/src/unicode/tables.rs 中对应 Rust 实现逐行对照翻译（固定模板，
见 FUNCTIONS_V；Rust 用 usize，值域都非负且很小，V 侧统一用 int）。

脚本可重复运行：同样的 tables.rs 总是生成同样的输出。
"""

import re
import sys

# 匹配 `const NAME: [u16; N] = [...];` 或 `const NAME: [[u32; M]; N] = [...];`
CONST_RE = re.compile(
    r"const\s+(\w+)\s*:\s*"
    r"(?:\[\s*\[\s*(u16|u32)\s*;\s*(\d+)\s*\]\s*;\s*(\d+)\s*\]"  # 二维 [[T; M]; N]
    r"|\[\s*(u16|u32)\s*;\s*(\d+)\s*\])"  # 一维 [T; N]
    r"\s*=\s*\[(.*?)\n\];",
    re.DOTALL,
)

HEADER = """module main

// ============================================================================
// 由 tools/rs_tables_to_v.py 生成，勿手改。
// 来源：microsoft/edit crates/edit/src/unicode/tables.rs
//       （unicode-gen 生成的 Unicode 16.0.0 三级查找表 + join 规则矩阵）
// 重新生成：python3 tools/rs_tables_to_v.py <tables.rs 路径> > unicode_tables.v
// ============================================================================
"""

# 8 个 ucd_* 函数，逐行对照 tables.rs 中的 Rust 实现翻译。
# Rust 用 usize 的地方一律用 int（值域非负且 << 2^31）。
FUNCTIONS_V = """
// ucd_grapheme_cluster_lookup 对照 Rust `ucd_grapheme_cluster_lookup`：
// cp < 0x80 直查 STAGE3，否则 STAGE0 -> STAGE1 -> STAGE2 -> STAGE3 三级级联。
@[inline]
fn ucd_grapheme_cluster_lookup(cp rune) int {
	cp_i := int(cp)
	if cp_i < 0x80 {
		return int(ucd_stage3[cp_i])
	}
	s1 := int(ucd_stage0[cp_i >> 11])
	s2 := int(ucd_stage1[s1 + ((cp_i >> 5) & 63)])
	s3 := int(ucd_stage2[s2 + ((cp_i >> 2) & 7)])
	return int(ucd_stage3[s3 + (cp_i & 3)])
}

// ucd_grapheme_cluster_joins 对照 Rust `ucd_grapheme_cluster_joins`：
// 状态机矩阵查询，lead/trail 取低 5 位，矩阵每元素 2 bit。
// Rust 的 GRAPHEME_JOIN_RULES[state][l] 在这里是拍平数组的
// state * stride + l（见 ucd_grapheme_join_rules 上方注释）。
@[inline]
fn ucd_grapheme_cluster_joins(state u32, lead int, trail int) u32 {
	l := lead & 31
	t := trail & 31
	s := ucd_grapheme_join_rules[int(state) * ucd_grapheme_join_rules_stride + l]
	return (s >> u32(t * 2)) & u32(3)
}

// ucd_grapheme_cluster_joins_done 对照 Rust `ucd_grapheme_cluster_joins_done`。
@[inline]
fn ucd_grapheme_cluster_joins_done(state u32) bool {
	return state == 3
}

// ucd_grapheme_cluster_character_width 对照 Rust
// `ucd_grapheme_cluster_character_width`：宽度打包在 bit 11 起，> 2 表示
// East Asian Ambiguous，取 ambiguous_width。Rust 原版的 cold_path() 只是
// 性能提示，无语义，这里省略。
@[inline]
fn ucd_grapheme_cluster_character_width(val int, ambiguous_width int) int {
	mut w := val >> 11
	if w > 2 {
		w = ambiguous_width
	}
	return w
}

// ucd_line_break_joins 对照 Rust `ucd_line_break_joins`：
// line break class 打包在 bit 6 起，取低 5 位；矩阵每元素 1 bit。
@[inline]
fn ucd_line_break_joins(lead int, trail int) bool {
	l := (lead >> 6) & 31
	t := (trail >> 6) & 31
	s := ucd_line_break_join_rules[l]
	return ((s >> u32(t)) & u32(1)) != 0
}

// ucd_start_of_text_properties 对照 Rust `ucd_start_of_text_properties`。
@[inline]
fn ucd_start_of_text_properties() int {
	return 0x603
}

// ucd_tab_properties 对照 Rust `ucd_tab_properties`。
@[inline]
fn ucd_tab_properties() int {
	return 0x963
}

// ucd_linefeed_properties 对照 Rust `ucd_linefeed_properties`。
@[inline]
fn ucd_linefeed_properties() int {
	return 0x802
}
"""


def parse_row(body, name):
    """把一段 Rust 数组字面量解析成 int 列表（支持 0x / 0b / 十进制）。"""
    vals = []
    for tok in body.replace("\n", " ").split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith(("0x", "0X")):
            vals.append(int(tok, 16))
        elif tok.startswith(("0b", "0B")):
            vals.append(int(tok, 2))
        else:
            vals.append(int(tok, 10))
    return vals


def parse_tables(text):
    """解析所有 const 静态数组。

    返回 {name: {'type': 'u16'|'u32', 'rows': [[int, ...], ...]}}；
    一维数组 rows 只有一行。元素个数与声明长度不符时报错。
    """
    tables = {}
    for m in CONST_RE.finditer(text):
        name = m.group(1)
        body = m.group(7)
        if m.group(2):  # 二维 [[T; M]; N]
            vtype, inner, outer = m.group(2), int(m.group(3)), int(m.group(4))
            rows_raw = re.findall(r"\[(.*?)\]", body, re.DOTALL)
            if len(rows_raw) != outer:
                raise ValueError(f"{name}: 声明 {outer} 行，解析到 {len(rows_raw)} 行")
            rows = [parse_row(r, name) for r in rows_raw]
            for r in rows:
                if len(r) != inner:
                    raise ValueError(f"{name}: 声明每行 {inner} 个，解析到 {len(r)} 个")
        else:  # 一维 [T; N]
            vtype, count = m.group(5), int(m.group(6))
            rows = [parse_row(body, name)]
            if len(rows[0]) != count:
                raise ValueError(
                    f"{name}: 声明 {count} 个元素，解析到 {len(rows[0])} 个"
                )
        limit = 0x10000 if vtype == "u16" else 0x100000000
        for r in rows:
            for v in r:
                if not (0 <= v < limit):
                    raise ValueError(f"{name}: 值 {v:#x} 超出 {vtype} 范围")
        tables[name] = {"type": vtype, "rows": rows}
    return tables


def wrap_row(vals, fmt, vtype, first_typed, per_line):
    """把一行元素格式化成多行 V 字面量片段（含行首 tab、行尾逗号）。"""
    parts = []
    for i in range(0, len(vals), per_line):
        segs = []
        for j, v in enumerate(vals[i : i + per_line]):
            s = fmt(v)
            if first_typed and i == 0 and j == 0:
                s = f"{vtype}({s})"
            segs.append(s)
        parts.append("\t" + ", ".join(segs) + ",")
    return parts


def emit_v(tables):
    lines = [HEADER]
    for name, t in tables.items():
        vname = "ucd_" + name.lower()
        vtype = t["type"]
        if vtype == "u16":
            fmt = lambda v: f"0x{v:04x}"
            per_line = 8
        else:
            fmt = lambda v: f"0b{v:032b}"
            per_line = 1
        rows = t["rows"]
        shape = (
            f"[{vtype}; {len(rows[0])}]"
            if len(rows) == 1
            else f"[[{vtype}; {len(rows[0])}]; {len(rows)}]"
        )
        lines.append(f"// Rust: const {name}: {shape}")
        if len(rows) == 1:
            lines.append(f"const {vname} = [")
            lines.extend(wrap_row(rows[0], fmt, vtype, True, per_line))
            lines.append("]!")
        else:
            # 二维数组拍平成一维 + stride 常量：V 0.5.2 对运行时下标索引二维
            # const fixed array 有 bug（数组长度出错导致 panic/segfault）。
            # 元素顺序与 Rust 完全一致（行优先）。
            inner = len(rows[0])
            flat = [v for r in rows for v in r]
            lines.append(
                f"// 注意：V 无法安全地用运行时下标索引二维 const fixed array，"
                f"已拍平成一维；行 stride = {inner}。"
            )
            lines.append(f"const {vname}_stride = {inner}")
            lines.append(f"const {vname} = [")
            lines.extend(wrap_row(flat, fmt, vtype, True, per_line))
            lines.append("]!")
        lines.append("")
    lines.append(FUNCTIONS_V)
    return "\n".join(lines)


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    with open(argv[1], "r", encoding="utf-8") as f:
        text = f.read()
    tables = parse_tables(text)
    sys.stdout.write(emit_v(tables))


if __name__ == "__main__":
    main(sys.argv)
