#!/usr/bin/env python3
"""lsh_tables_to_v.py — 把 lsh-bin compile 生成的 lsh_definitions.rs 机械转换为 V。

用法：
    CARGO_TARGET_DIR=/tmp/lsh-target cargo build -p lsh-bin --release   # 一次性
    /tmp/lsh-target/release/lsh-bin compile <edit>/crates/lsh/definitions > /tmp/lsh_definitions.rs
    python3 tools/lsh_tables_to_v.py /tmp/lsh_definitions.rs > lsh_tables.v

（构建 lsh-bin 时务必设 CARGO_TARGET_DIR 指到仓库外，参考源码树保持只读。）

生成内容（对照 lsh/src/compiler/generator.rs 的 generate_rust 输出）：
- lsh_kind_* 常量（HighlightKind 枚举值）
- lsh_languages（Language 表：id/name/entrypoint）
- lsh_file_associations（文件 glob → 语言索引）
- lsh_assembly / lsh_strings / lsh_charsets（VM 字节码与常量表，
  charsets 摊平为 16 个 u16 一组）

脚本可重复运行：同样的输入总是生成同样的输出。
"""

import re
import sys

HEADER = """module main

// ============================================================================
// 由 tools/lsh_tables_to_v.py 生成，勿手改。
// 来源：microsoft/edit crates/lsh/definitions/*.lsh 经 lsh-bin compile 生成的
//       lsh_definitions.rs（VM 字节码 + 字符串/字符集/语言/文件关联表）
// 重新生成：见 tools/lsh_tables_to_v.py 头部注释
// ============================================================================
"""

# Rust debug 格式字符串字面量 -> Python str
RUST_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "0": "\0"}


def decode_rust_string(lit):
    assert lit.startswith('"') and lit.endswith('"'), lit
    out = []
    i = 1
    while i < len(lit) - 1:
        c = lit[i]
        if c == "\\":
            i += 1
            e = lit[i]
            if e == "u":
                assert lit[i + 1] == "{"
                j = lit.index("}", i)
                out.append(chr(int(lit[i + 2 : j], 16)))
                i = j + 1
                continue
            out.append(RUST_ESCAPES[e])
        else:
            out.append(c)
        i += 1
    return "".join(out)


def encode_v_string(s):
    body = s.replace("\\", "\\\\").replace("'", "\\'")
    body = body.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r").replace("\0", "\\0")
    return f"'{body}'"


def snake(name):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", name).lower()


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", text)


def parse_static_array(data, name, dtype):
    """解析 `pub static NAME: [dtype; N] = [...]`，返回元素字符串列表。"""
    m = re.search(
        r"pub static " + name + r": \[" + dtype + r"; (\d+)\] = \[(.*?)\n\];",
        data,
        re.DOTALL,
    )
    if not m:
        raise ValueError(f"static {name} not found")
    count, body = int(m.group(1)), strip_comments(m.group(2))
    items = [x.strip() for x in body.split(",") if x.strip()]
    if len(items) != count:
        raise ValueError(f"{name}: declared {count}, parsed {len(items)}")
    return items


def emit_v(data):
    out = [HEADER]

    # --- HighlightKind 枚举 ---
    m = re.search(r"enum HighlightKind \{(.*?)\n\}", data, re.DOTALL)
    kinds = re.findall(r"(\w+) = (\d+),", strip_comments(m.group(1)))
    out.append("// HighlightKind 值（对照生成的 Rust enum HighlightKind）")
    for name, val in kinds:
        out.append(f"pub const lsh_kind_{snake(name)} = u32({val})")
    out.append("")

    # --- LANGUAGES ---
    m = re.search(r"pub static LANGUAGES: &\[Language\] = &\[(.*?)\n\];", data, re.DOTALL)
    langs = re.findall(
        r'Language \{ id: ("(?:[^"\\]|\\.)*"), name: ("(?:[^"\\]|\\.)*"), entrypoint: (\d+) \}',
        m.group(1),
    )
    out.append("// 语言表（对照生成的 static LANGUAGES）")
    out.append("pub const lsh_languages = [")
    for lid, lname, ep in langs:
        out.append(
            f"\tLshLanguage{{ id: {encode_v_string(decode_rust_string(lid))}, "
            f"name: {encode_v_string(decode_rust_string(lname))}, entrypoint: u32({ep}) }},"
        )
    out.append("]")
    out.append("")

    # --- FILE_ASSOCIATIONS ---
    m = re.search(
        r"pub static FILE_ASSOCIATIONS: &\[ \(&str, &Language\) \] = &\[(.*?)\n\];"
        r"|pub static FILE_ASSOCIATIONS: &\[\(&str, &Language\)\] = &\[(.*?)\n\];",
        data,
        re.DOTALL,
    )
    body = m.group(1) if m.group(1) is not None else m.group(2)
    assoc = re.findall(r'\(("(?:[^"\\]|\\.)*"), &LANGUAGES\[(\d+)\]\),', body)
    out.append("// 文件名 glob → lsh_languages 索引（对照 static FILE_ASSOCIATIONS）")
    out.append("pub const lsh_file_associations = [")
    for pat, idx in assoc:
        out.append(f"\tLshAssociation{{ pattern: {encode_v_string(decode_rust_string(pat))}, lang: {idx} }},")
    out.append("]")
    out.append("")

    # --- ASSEMBLY ---
    items = parse_static_array(data, "ASSEMBLY", r"u8")
    out.append(f"// VM 字节码（对照 static ASSEMBLY，含 16 字节 0xff 结尾 padding）")
    out.append("pub const lsh_assembly = [")
    for i in range(0, len(items), 16):
        cells = [f"u8({items[i]})"] + items[i + 1 : i + 16]
        out.append("\t" + ", ".join(cells) + ",")
    out.append("]!")
    out.append("")

    # --- CHARSETS（摊平）---
    m = re.search(r"pub static CHARSETS: \[\[u16; 16\]; (\d+)\] = \[(.*?)\n\];", data, re.DOTALL)
    n_sets, body = int(m.group(1)), strip_comments(m.group(2))
    cells = [x.strip() for x in body.replace("[", "").replace("]", "").split(",") if x.strip()]
    if len(cells) != n_sets * 16:
        raise ValueError(f"CHARSETS: expected {n_sets * 16}, parsed {len(cells)}")
    out.append("// 字符集位图，摊平为 16 个 u16 一组（对照 static CHARSETS）")
    out.append("pub const lsh_charsets = [")
    for i in range(0, len(cells), 16):
        row = [f"u16({cells[i]})"] + cells[i + 1 : i + 16]
        out.append("\t" + ", ".join(row) + ",")
    out.append("]!")
    out.append("")

    # --- STRINGS ---
    m = re.search(r"pub static STRINGS: \[&str; (\d+)\] = \[(.*?)\n\];", data, re.DOTALL)
    count, body = int(m.group(1)), m.group(2)
    strs = re.findall(r'"(?:[^"\\]|\\.)*"', body)
    if len(strs) != count:
        raise ValueError(f"STRINGS: declared {count}, parsed {len(strs)}")
    out.append("// 前缀匹配字符串表（对照 static STRINGS）")
    out.append("pub const lsh_strings = [")
    for lit in strs:
        out.append("\t" + encode_v_string(decode_rust_string(lit)) + ",")
    out.append("]")

    return "\n".join(out) + "\n"


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 1
    with open(argv[1]) as f:
        data = f.read()
    sys.stdout.write(emit_v(data))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
