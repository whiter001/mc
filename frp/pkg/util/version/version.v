module version

// version 是 vfrp 的版本号，与 v.mod 中的 version 保持一致。
pub const version = '0.1.0'

// proto_version 是 wire protocol（帧格式）版本号。
// v1 = [1 字节类型][JSON payload]['\n']，见 plan.md §4。
pub const proto_version = 1
