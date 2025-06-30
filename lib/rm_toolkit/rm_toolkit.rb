# lib/rm_toolkit.rb

# frozen_string_literal: true

# 核心职责 1: 加载所有内部依赖
# 注意 require_relative 的路径变化，因为文件都被移动到 rm_toolkit/ 子目录了
require_relative 'version'
require_relative 'logging'
require_relative 'utils'
require_relative 'configuration'
require_relative 'version_detector'
require_relative 'snapshot_manager'
require_relative 'converter'
require_relative 'shared'
require_relative 'rgss_extensions'

# --- 修改开始 ---
# 引入新的集中式版本加载器，而不是直接加载 rgss1/2/3.rb
require_relative 'rgss/loader'
# --- 修改结束 ---

require_relative 'rgss_handler'
require_relative 'mv_mz_handler'
require_relative 'application'

# 核心职责 2: 定义顶层模块
module RmToolkit
  class Error < StandardError; end

  # 你可以在这里定义一些供 gem 用户直接调用的顶层 API
  # 例如，提供一个简单的方式来运行应用
  def self.run(argv = ARGV)
    Application.new(argv).run
  end
end