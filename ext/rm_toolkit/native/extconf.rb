require 'mkmf'

# 检查并添加对 liburing 的链接
have_library('uring')

# --- 新增/修改这一行 ---
# 确保链接 pthread 库，用于信号量和线程
$LIBS << " -lpthread"

create_makefile("rm_toolkit/native")