# kimi-v agent 指南

## 资源限制（必须遵守）

当前 V 工具链可能不稳定，编译或测试进程有时会失控占满 CPU，拖垮整个系统。
**凡是跑 V 编译 / 测试 / 静态检查的命令，一律用 `cpulimit` 包一层限制 CPU 占用**：

```bash
cpulimit -l 200 -z -- ./build.sh        # dev build，限制在约 2 核
cpulimit -l 200 -z -- ./build.sh test   # 跑测试
cpulimit -l 200 -z -- ./build.sh prod   # prod build
cpulimit -l 200 -z -- v fmt -w .        # fmt / vet 等直接调 v 的命令同理
```

- `-l N`：允许的 CPU 百分比，按核数计（0–800，即 100 = 1 核）。默认用 200，机器较弱时降到 100。
- `-z`：目标进程退出后 cpulimit 自动退出，不会残留。
- cpulimit 不在 PATH 里时先问用户，不要自己安装。
- 限制的只是构建/测试进程；对最终产出的二进制正常运行不加限制。
- 内存限制已内置于 `build.sh`：编译和测试命令自带内存看门狗，进程树 RSS 超限会被整树杀掉，防止内存泄露把系统搞死机。build 用 `MEMLIMIT_MB`（默认 2048MB），`v test` 单独用 `TEST_MEMLIMIT_MB`（默认 4096MB）；`MEMLIMIT_MB=0` 整体关闭。（2026-08 实测峰值：dev 469MB / prod 881MB / test 2161~3241MB——test 要并行编译全部 test target，峰值随并行度波动、远高于 build，2048/3072 都会误杀正常测试，故分开。）
- 直接调用 `v` 的命令（如 `v fmt -w .`）没有经过 build.sh，没有内存限制，至少仍要包 `cpulimit`。
