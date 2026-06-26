# lib/rm_toolkit/rgss/loader.rb
# frozen_string_literal: true

require_relative '../logging'

module RPG
  class Loader
    VERSION_DIRS = {
      "RGSS1" => "xp",
      "RGSS2" => "vx",
      "RGSS3" => "vx_ace",
    }.freeze

    @loaded_version = nil
    @lock = Mutex.new

    class << self
      def load(version)
        @lock.synchronize do
          if @loaded_version && @loaded_version != version
            raise "错误: 已加载 RGSS 版本 '#{@loaded_version}', 无法再加载 '#{version}'。程序状态不一致，必须中止。"
          end

          unless @loaded_version == version
            dir = VERSION_DIRS[version] or raise "未知版本: #{version}"
            Logging::Log.info "RPG::Loader 正在加载版本定义: #{version}"

            base = File.join(__dir__, dir)
            unless Dir.exist?(base)
              raise LoadError, "版本定义目录不存在: #{base}"
            end

            # 1. 加载 Jsonable 模块（只一次）
            mixins_dir = File.join(__dir__, "mixins")
            Dir[File.join(mixins_dir, "*.rb")].sort.each { |f| require f }

            # 2. 加载基础类型（rgss/）
            Dir[File.join(base, "rgss", "*.rb")].sort.each { |f| require f }

            # 3. 加载 RPG 类（rpg/），基类优先
            rpg_files = Dir[File.join(base, "rpg", "*.rb")]
            %w[base_item usable_item equip_item].each do |base_name|
              f = rpg_files.find { |ff| File.basename(ff) == "#{base_name}.rb" }
              rpg_files.delete(f) && require(f) if f
            end
            rpg_files.sort.each { |f| require f }

            @loaded_version = version
            Logging::Log.info "成功加载 RGSS 版本定义: #{version}"
          end
          true
        end
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