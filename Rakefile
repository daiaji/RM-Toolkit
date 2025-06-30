# frozen_string_literal: true

# 加载 rake-compiler 提供的 C 扩展编译任务
require 'rake/extensiontask'
# 加载 bundler 提供的 gem 打包和发布任务 (如 rake build, rake release)
require 'bundler/gem_tasks'

# --- 核心：定义 C 扩展编译任务 ---
# 这里的 "rm_toolkit/native" 是关键。它必须与 extconf.rb 中的
# create_makefile("rm_toolkit/native") 参数完全一致。
# rake-compiler 会根据这个名称智能地执行以下操作：
# 1. 查找源文件于：ext/rm_toolkit/native/
# 2. 将编译产物（.so/.bundle/.dll）放置于：lib/rm_toolkit/
Rake::ExtensionTask.new('rm_toolkit/native') do |ext|
  # 注意：我们不需要像旧方法那样设置 `ext.lib_dir = "lib"`。
  # `rake-compiler` 的现代用法会自动将产物放到正确的位置，
  # 使我们的配置更简洁、更标准。
end

# --- 定义默认任务 ---
# 当你在终端只运行 `bundle exec rake` 时，默认会执行 :compile 任务。
task default: :compile

# --- 定义清理任务 ---
# 这个任务至关重要，用于移除所有编译产物，确保可以进行一次全新的编译。
task :clean do
  puts "==> Cleaning C extension artifacts..."

  # 定义一个包含所有已知编译产物和中间文件扩展名的数组
  # 这样可以跨平台（Linux .so, macOS .bundle, Windows .dll）地进行清理
  native_exts = %w[.so .bundle .dll .o .obj]

  # 1. 清理 C 扩展源目录下的临时文件和编译产物
  puts "  -> Cleaning in ext/rm_toolkit/native/"
  rm_rf 'ext/rm_toolkit/native/Makefile'
  rm_rf 'ext/rm_toolkit/native/mkmf.log'
  rm_rf 'ext/rm_toolkit/native/conftest*'
  rm_rf 'ext/rm_toolkit/native/.gem.*' # rake-compiler 可能留下的临时文件
  # 使用 glob 安全地删除编译产物，避免误删其他文件
  Dir.glob("ext/rm_toolkit/native/*{#{native_exts.join(',')}}").each do |f|
    puts "     - Removing intermediate file: #{f}"
    rm_f(f)
  end

  # 2. 清理 rake-compiler 在项目根目录下生成的临时目录
  puts "  -> Cleaning tmp/ directory"
  rm_rf 'tmp'

  # 3. 安全地清理最终安装到 lib/ 目录下的产物
  # 这是最关键的清理步骤，确保只删除 .so/.bundle/.dll 文件，绝不触碰 .rb 源代码。
  puts "  -> Cleaning final native extensions in lib/rm_toolkit/"
  # 使用 Dir.glob 配合扩展名数组，精确地只删除编译后的本地扩展文件
  Dir.glob("lib/rm_toolkit/native{#{native_exts.join(',')}}").each do |f|
    puts "     - Removing final extension: #{f}"
    rm_f(f)
  end

  puts "==> Clean task finished."
end

# 将我们自定义的 clean 任务添加到 Bundler 的 clobber 任务链中。
# clobber 是比 clean 更彻底的清理，通常在打包发布前使用。
# 这样做可以确保 `rake clobber` 会执行我们定义的清理逻辑。
if Rake::Task.task_defined?("clobber")
  Rake::Task[:clobber].enhance Rake::Task[:clean].prerequisites
end