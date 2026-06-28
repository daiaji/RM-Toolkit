# RM-Toolkit

RPG Maker 游戏数据文件转换工具。支持 RGSS1/2/3（`.rxdata` / `.rvdata` / `.rvdata2`）以及 MV/MZ 游戏项目的解包、封包、脚本处理。

## Acknowledgments

This project builds upon the work of several great open-source projects:

- **[rgss-db-cli](https://github.com/SnowSzn/rgss-db-cli)** (GPL-3.0) — Ruby 实现的 RGSS 数据库导出/导入工具，提供了完整的 RGSS 类型定义和 JSON 转换参考
- **[R3EXS](https://github.com/LuoTat/R3EXS)** (MIT) — RGSS3 字符串提取/注入工具，提供了**高速 RGSS3A 解密 C 扩展实现参考**（AVX2 向量化，含 Fux2Pack2 加密格式）以及 **Scripts.rxdata/.rvdata2 解包/封包流程参考**
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

RPG Maker 的脚本文件（`Scripts.rvdata2`）会被解包为独立的 `.rb` 文件及元数据。
解包一次后，后续脚本操作会自动更新 `Data/Scripts.*`，无需每次指定 `--pack`。

```
# 解包脚本
rm-toolkit --base-dir /path/to/game --unpack --rgss3

# 列出脚本
rm-toolkit --base-dir /path/to/game --rgss3 --list-scripts

# 导出单个脚本到文件
rm-toolkit --base-dir /path/to/game --rgss3 --export-script 3
rm-toolkit --base-dir /path/to/game --rgss3 --export-script 5:out.rb

# 注入脚本（插入到指定序号，原序号及后续后移）
rm-toolkit --base-dir /path/to/game --rgss3 --inject-script 0:patch.rb

# 注入多个脚本（按顺序依次插入）
rm-toolkit --base-dir /path/to/game --rgss3 \
  --inject-script 0:compat.rb \
  --inject-script 1:patch.rb

# 替换脚本内容（保留序号）
rm-toolkit --base-dir /path/to/game --rgss3 --replace-script 3:fix.rb

# 创建空脚本
rm-toolkit --base-dir /path/to/game --rgss3 --create-script 2

# 清空脚本内容（保留位置和名称）
rm-toolkit --base-dir /path/to/game --rgss3 --clear-script 5

# 删除指定索引的脚本
rm-toolkit --base-dir /path/to/game --rgss3 --remove-script 42

# 批量删除空脚本
rm-toolkit --base-dir /path/to/game --rgss3 --prune-empty-scripts

# 重命名脚本
rm-toolkit --base-dir /path/to/game --rgss3 --rename-script "3:新名称"

# 移动脚本位置
rm-toolkit --base-dir /path/to/game --rgss3 --move-script 10:3

# 手动修改 Source/scripts/ 下的文件后，重新封包脚本
rm-toolkit --base-dir /path/to/game --rgss3 --repack-scripts

# 全量封包（脚本 + 所有数据文件）
rm-toolkit --base-dir /path/to/game --pack --rgss3

# 全量封包时仅处理脚本，跳过数据文件
rm-toolkit --base-dir /path/to/game --pack --rgss3 --scripts-only
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
| `--reconstruct` | 重建项目结构（解包前） |
| `-e, --extract-archive FILE` | 独立提取 RGSSAD 存档 |
| `-o, --extract-output-dir DIR` | 独立提取的输出目录 |
| `--create-snapshot [NAME]` | 创建快照 |
| `--list-snapshots` | 列出快照 |
| `--restore-snapshot NAME` | 恢复快照 |
| `--log-level LEVEL` | 设置日志级别（DEBUG/INFO/WARN/ERROR） |
| | **脚本管理（统一格式：`索引:参数`）** |
| `--list-scripts` | 列出所有脚本的序号和名称 |
| `--export-script SPEC` | 导出脚本到文件（格式：`索引` 或 `索引:输出路径`） |
| `--create-script INDEX` | 创建空脚本，原序号后移 |
| `--clear-script INDEX` | 清空脚本内容，保留位置和名称 |
| `--remove-script INDEX` | 删除指定序号的脚本，后续前移 |
| `--prune-empty-scripts` | 删除所有空脚本 |
| `--rename-script SPEC` | 重命名脚本（格式：`索引:新名称`） |
| `--move-script SPEC` | 移动脚本位置（格式：`源索引:目标索引`） |
| `--inject-script SPEC` | 注入脚本文件（格式：`索引:文件路径`，可多次使用） |
| `--replace-script SPEC` | 替换脚本内容（格式：`索引:文件路径`，可多次使用） |
| `--scripts-only` | 仅处理脚本，不处理其他数据文件 |
| `--repack-scripts` | 重新封包脚本（Source/scripts/ → Data/Scripts.*），等效 `--pack --scripts-only` |
