# lib/rm_toolkit/rgss/loader.rb
# frozen_string_literal: true

require_relative '../logging'

module RPG
  class Loader
    @loaded_version = nil
    # --- 修改开始 ---
    # 直接实例化一个 Mutex 对象，而不是 include mixin
    @lock = Mutex.new 
    # --- 修改结束 ---

    class << self
      def load(version)
        # --- 修改开始 ---
        # 调用实例化的 @lock 对象的 synchronize 方法
        @lock.synchronize do
        # --- 修改结束 ---
          if @loaded_version && @loaded_version != version
            raise "错误: 已加载 RGSS 版本 '#{@loaded_version}', 无法再加载 '#{version}'。程序状态不一致，必须中止。"
          end
          
          unless @loaded_version == version
            Logging::Log.info "RPG::Loader 正在加载版本定义: #{version}"
            begin
              require_relative "../#{version.downcase}"
              @loaded_version = version
              Logging::Log.info "成功加载 RGSS 版本定义: #{version}"
            rescue LoadError => e
              err_msg = "无法加载 RGSS 版本定义文件 for '#{version}'。请确保 'lib/rm_toolkit/#{version.downcase}.rb' 文件存在。原始错误: #{e.message}"
              Logging::Log.fatal err_msg
              raise LoadError, err_msg
            end
          else
            Logging::Log.debug "RGSS 版本 '#{version}' 的定义已经加载，跳过。"
          end
        end
        true
      end

      def loaded?
        !@loaded_version.nil?
      end

      def current_version
        @loaded_version
      end

      def reset!
        @lock.synchronize do
          @loaded_version = nil
          Logging::Log.warn "RPG::Loader 状态已重置。注意：已定义的类无法被移除。"
        end
      end
    end
  end
end