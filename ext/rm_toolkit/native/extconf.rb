require 'mkmf'

# 1. 添加 CFLAGS 以启用优化和指令集
#    -O3 是最高级别的优化
#    -march=native 会让编译器为当前编译代码的机器进行专门优化。
append_cflags('-O3')
append_cflags('-march=native')

# 2. 在非 Windows 系统上，链接 pthread 库以支持多线程
unless Gem.win_platform?
  have_library('pthread')
end

# 创建 Makefile
# $LIBS 在 have_library('pthread') 成功后会自动添加 "-lpthread"
create_makefile("rm_toolkit/native")