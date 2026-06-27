# frozen_string_literal: true

# 路径已更新，以匹配新的 lib/rm_toolkit/ 目录结构
require_relative 'lib/rm_toolkit/version'

Gem::Specification.new do |spec|
  # gem 名称使用连字符，这是社区标准
  spec.name        = 'rm-toolkit'
  spec.version     = RmToolkit::VERSION
  spec.authors     = ['Your Name'] # <-- 请替换成您的名字
  spec.email       = ['your.email@example.com'] # <-- 请替换成您的邮箱

  spec.summary     = 'A tool to convert RPG Maker data files and decrypt assets.'
  spec.description = 'A comprehensive toolkit for converting RPG Maker data files (from XP, VX, VX Ace) to JSON, and for decrypting/extracting assets from RGSSAD, MV, and MZ game archives.'
  spec.homepage    = 'https://github.com/daiaji/RM-Toolkit'
  spec.license     = 'GPL-3.0'

  # 防止将不必要的文件打包进 gem。
  # 这个 glob 模式是正确的，它会包含 ext/rm_toolkit/native/ 下的所有文件。
  spec.files = Dir.glob('{exe,lib,ext}/**/*', File::FNM_DOTMATCH).reject do |f|
    # 剔除目录、测试文件和临时文件，但保留编译好的 .so, .bundle, .dylib 文件
    File.directory?(f) || f.match?(%r{^(test|spec|features)/}) || f.match?(/(\.(?!so|bundle|dylib)\w+|~)$/)
  end + ['README.md', 'config.yaml']

  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }

  # 关键修改：`require_paths` 只需要包含 'lib'。
  # `rake-compiler` 会将编译好的 C 扩展放到 lib/ 目录下，
  # 而 Bundler/RubyGems 会在构建时自动处理 ext/ 目录。
  # 这是更现代和标准的做法。
  spec.require_paths = ['lib']

  # C 扩展的配置脚本路径保持不变，这是正确的。
  spec.extensions = ['ext/rm_toolkit/native/extconf.rb']

  # --- 运行时依赖 ---
  spec.add_dependency 'oj'
  spec.add_dependency 'inifile'
  spec.add_dependency 'rchardet'

  # --- 开发时依赖 ---
  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rake-compiler'
  spec.add_development_dependency 'ruby-lsp'
  spec.add_development_dependency 'debug'
end