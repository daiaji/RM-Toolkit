# RM-Toolkit

RPG Maker 游戏数据文件转换工具。支持 RGSS1/2/3（`.rxdata` / `.rvdata` / `.rvdata2`）以及 MV/MZ 游戏项目的解包、封包、脚本处理。

## Acknowledgments

This project builds upon the work of several great open-source projects:

- **[rgss-db-cli](https://github.com/SnowSzn/rgss-db-cli)** (GPL-3.0) — Ruby 实现的 RGSS 数据库导出/导入工具，提供了完整的 RGSS 类型定义和 JSON 转换参考
- **[R3EXS](https://github.com/LuoTat/R3EXS)** (MIT) — RGSS3 字符串提取/注入工具，提供了**高速 RGSS3A 解密 C 扩展实现参考**（AVX2 向量化）以及 **Scripts.rxdata/.rvdata2 解包/封包流程参考**
- **[RPGMakerDecrypter](https://github.com/uuksu/RPGMakerDecrypter)** (MIT) — C# 实现的 RPG Maker 归档文件解密工具，提供了 RGSS1/2 归档解密以及 MV/MZ 媒体文件加解密的参考实现（翻译为 C 原生代码）

## License

Licensed under GPL-3.0. See [LICENSE](LICENSE) for details.

## Usage

### Requirements

- Ruby 3.0+
- `gem install rm-toolkit`
- 可选：编译 C 扩展以启用 RGSSAD 解包和 MV/MZ 媒体解密功能

### RGSS1/2/3 解包

将 RPG Maker XP/VX/VX Ace 的 Data 目录转换为可编辑的 JSON：

```
rm-toolkit --base-dir /path/to/game --unpack --rgss3
```

默认输入目录为 `Data/`，输出目录为 `Source/`。

### RGSS1/2/3 封包

将编辑后的 JSON 写回为游戏可读的二进制格式：

```
rm-toolkit --base-dir /path/to/game --pack --rgss3
```

### 脚本处理

RPG Maker 的脚本文件（`Scripts.rvdata2`）会被解包为独立的 `.rb` 文件及元数据：

```
# 解包脚本
rm-toolkit --base-dir /path/to/game --unpack --rgss3

# 封包时删除指定索引的脚本
rm-toolkit --base-dir /path/to/game --pack --rgss3 --remove-script 42

# 封包时清理所有空脚本
rm-toolkit --base-dir /path/to/game --pack --rgss3 --prune-empty-scripts
```

### RGSSAD 存档独立提取

```
rm-toolkit --base-dir /path/to/game -e Game.rgss3a -o ./extracted
```

### 快照管理

在对源码目录进行操作前自动创建快照，以便回滚：

```
rm-toolkit --base-dir /path/to/game --unpack --rgss3 --create-snapshot
rm-toolkit --base-dir /path/to/game --list-snapshots
rm-toolkit --base-dir /path/to/game --restore-snapshot my_backup
```

### MV/MZ 支持

除 RGSS 引擎外，也支持 RPG Maker MV/MZ 项目的解包（解密媒体文件、提取脚本等）：

```
rm-toolkit --base-dir /path/to/game --unpack --mv
rm-toolkit --base-dir /path/to/game --unpack --mz
```

### 完整选项

| 选项 | 说明 |
|------|------|
| `-b, --base-dir DIR` | 指定基准目录（默认：当前目录） |
| `-u, --unpack` | 解包/解密模式 |
| `-p, --pack` | 封包模式（仅 RGSS1/2/3） |
| `-w, --overwrite` | 覆盖已存在的目标文件 |
| `--rgss1` | 强制使用 RGSS1（XP） |
| `--rgss2` | 强制使用 RGSS2（VX） |
| `--rgss3` | 强制使用 RGSS3（VX Ace） |
| `--mv` | 强制使用 RPG Maker MV |
| `--mz` | 强制使用 RPG Maker MZ |
| `--strict` | 遇到第一个文件错误即中止 |
| `--remove-script INDEX` | 删除指定索引的脚本（仅 --pack） |
| `--prune-empty-scripts` | 删除所有空脚本（仅 --pack） |
| `--reconstruct` | 重建项目结构（解包前） |
| `-e, --extract-archive FILE` | 独立提取 RGSSAD 存档 |
| `-o, --extract-output-dir DIR` | 独立提取的输出目录 |
| `--create-snapshot [NAME]` | 创建快照 |
| `--list-snapshots` | 列出快照 |
| `--restore-snapshot NAME` | 恢复快照 |
| `--log-level LEVEL` | 设置日志级别（DEBUG/INFO/WARN/ERROR） |
