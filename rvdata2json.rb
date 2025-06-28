#!/usr/bin/env ruby
# rvdata2json 主脚本
# 负责在 RVData (Marshal) 和 JSON 格式之间转换 RPG Maker 数据文件，
# 并支持 RGSSAD 存档提取与 MV/MZ 项目解密。

# 设置 Ruby 加载路径，确保能找到 lib 目录和 C 扩展
# __dir__ 是当前脚本文件所在的目录
lib_path = File.expand_path("lib", __dir__)
# extconf.rb 指定了 'rpg_maker_tools/rpg_maker_tools'，所以需要 'ext' 目录在路径中
ext_path = File.expand_path("ext", __dir__)

$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
$LOAD_PATH.unshift(ext_path) unless $LOAD_PATH.include?(ext_path)

# 加载应用核心类
require "application"

# 创建 Application 实例并运行
# ARGV 是命令行参数数组
Application.new(ARGV).run