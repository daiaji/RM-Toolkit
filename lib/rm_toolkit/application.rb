# RM-Toolkit/lib/application.rb
require 'optparse'
require 'pathname'
require 'fileutils'

# 提前加载，确保 C 扩展路径设置正确
lib_path = File.expand_path(__dir__)
ext_path = File.expand_path(File.join(__dir__, '..', 'ext'))
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
$LOAD_PATH.unshift(ext_path) unless $LOAD_PATH.include?(ext_path)

# 尝试加载 C 扩展
begin
  require 'rm_toolkit/native'
  NATIVE_TOOLS_LOADED = true
rescue LoadError => e
  NATIVE_TOOLS_LOADED = false
  # 在这里添加一个临时的警告，因为 Logging 模块此时可能还未初始化
  # 这个警告会在 Logging 初始化后被更详细的日志覆盖
  $stderr.puts "[初始警告] 原生 C 扩展加载失败。存档提取和 MV/MZ 解密功能将不可用。"
  $stderr.puts "[初始警告] 详情: #{e.message}"
end

require_relative 'logging'
require_relative 'configuration'
require_relative 'version_detector'
require_relative 'rgss_handler'
require_relative 'mv_mz_handler'
require_relative 'snapshot_manager'

class Application
  RGSS_VERSIONS = %w[RGSS1 RGSS2 RGSS3 MV MZ].freeze
  DEFAULT_STANDALONE_EXTRACT_DIR = "extracted_archive".freeze

  def initialize(argv)
    @argv = argv
    @options = {
      config: nil, base_dir: nil, log_level: nil, log_dir: nil,
      unpack: false, pack: false, overwrite: false, reconstruct: false, strict: false,
      rgss_version: nil, extract_archive_path: nil, extract_output_path: nil,
      include_dirs: [],
      # --- 脚本操作选项 (格式: 索引:参数) ---
      list_scripts: false,          # 列出脚本
      script_create_index: nil,     # 创建空脚本的目标索引
      script_clear_index: nil,      # 清空脚本的目标索引
      script_rename: nil,           # 重命名: [索引, 新名称]
      script_export: nil,           # 导出: [索引, 输出路径]
      script_move: nil,             # 移动: [源索引, 目标索引]
      scripts_only: false,          # 仅处理脚本，不碰其他数据文件
      inject_scripts: [],           # 注入列表: [[索引, 路径], ...]
      replace_scripts: [],           # 替换列表: [[索引, 路径], ...]
      # --- 快照相关选项 ---
      snapshot_task: nil,       # :create, :list, :restore
      snapshot_name: nil,       # 用于 create 和 restore 的名称
      force_restore: false,     # 用于跳过恢复时的确认
    }
    @base_dir = nil
    @config = nil
  end

  def run
    parse_options
    determine_base_directory
    load_configuration
    Logging.setup_logger(@config, @base_dir, @options[:log_level], @options[:log_dir])
    
    # --- 任务分派 ---
    if @options[:snapshot_task]
      handle_snapshot_task
    elsif @options[:extract_archive_path]
      handle_standalone_extraction
    else
      handle_regular_processing
    end
    
    Logging::Log.info "所有操作成功完成。"
  rescue => e
    Logging::Log.fatal "执行失败: #{e.class}: #{e.message}\n#{e.backtrace.first(15).join("\n")}"
    exit 1
  end

  private

  def handle_snapshot_task
    manager = SnapshotManager.new(@base_dir, @config)
    case @options[:snapshot_task]
    when :create
      manager.create(@options[:snapshot_name])
    when :list
      manager.list
    when :restore
      manager.restore(@options[:snapshot_name], @options[:force_restore])
    end
  end
  
  def handle_standalone_extraction
    raise "错误: 独立存档提取模式需要原生工具 C 扩展，但加载失败。" unless NATIVE_TOOLS_LOADED
    Logging::Log.info "进入独立存档提取模式..."
    input_path = File.expand_path(@options[:extract_archive_path], @base_dir)
    output_path = @options[:extract_output_path] ? File.expand_path(@options[:extract_output_path]) : File.expand_path(DEFAULT_STANDALONE_EXTRACT_DIR, Dir.pwd)
    FileUtils.mkdir_p(output_path)
    RmToolkitNative.extract_rgssad(input_path, output_path, Logging::Log.debug?)
    Logging::Log.info "存档已提取到: #{output_path}"
  end
  
  def handle_regular_processing
    # 独立运行的操作 (无需 unpack/pack)
    if @options[:list_scripts]
      handle_list_scripts; return
    end
    if @options[:script_export]
      handle_export_script; return
    end
    
    # 确定操作模式是否有效（脚本操作可独立运行）
    has_script_op = @options[:script_create_index] || @options[:script_clear_index] ||
                    @options[:script_rename] || @options[:script_move] ||
                    !@options[:inject_scripts].empty? || !@options[:replace_scripts].empty? ||
                    @options[:remove_script] || @options[:prune_empty_scripts]
    unless @options[:unpack] || @options[:pack] || has_script_op
      raise "错误: 必须指定一个主要操作模式，例如 --unpack, --pack, 或一个脚本操作命令。"
    end
    
    detected_version = VersionDetector.detect(@base_dir)
    final_version = @options[:rgss_version] || detected_version || @config["rgss_version"]
    
    unless RGSS_VERSIONS.include?(final_version)
      raise "无法确定有效的项目版本。请检查项目目录或使用 --rgssX/--mv/--mz 参数强制指定。"
    end
    
    Logging::Log.info "最终决策的项目版本为: #{final_version}"
    
    handler_class = case final_version
                    when "RGSS1", "RGSS2", "RGSS3" then RgssHandler
                    when "MV", "MZ" then MvMzHandler
                    end
    
    handler = handler_class.new(@options, @config, final_version)
    handler.process
  end

  def handle_list_scripts
    require 'zlib'
    
    ext_map = {"RGSS1" => ".rxdata", "RGSS2" => ".rvdata", "RGSS3" => ".rvdata2"}
    detected = VersionDetector.detect(@base_dir)
    version = @options[:rgss_version] || detected || @config["rgss_version"]
    ext = ext_map[version]
    
    scripts_path = File.join(@base_dir, "Data", "Scripts#{ext}")
    unless File.exist?(scripts_path)
      Logging::Log.warn "未找到脚本文件: #{scripts_path}"
      return
    end
    
    scripts = Marshal.load(File.binread(scripts_path))
    
    Logging::Log.info "===== 脚本列表 (#{scripts.size} 个) ====="
    scripts.each_with_index do |entry, idx|
      name = entry[1].dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      Logging::Log.result("#{format('%03d', idx)}|#{name}")
    end
    Logging::Log.info "================================"
  rescue => e
    Logging::Log.error "列出脚本失败: #{e.message}"
  end

  def handle_export_script
    require 'zlib'

    index, output_path = @options[:script_export]

    ext_map = {"RGSS1" => ".rxdata", "RGSS2" => ".rvdata", "RGSS3" => ".rvdata2"}
    detected = VersionDetector.detect(@base_dir)
    version = @options[:rgss_version] || detected || @config["rgss_version"]
    ext = ext_map[version]

    scripts_path = File.join(@base_dir, "Data", "Scripts#{ext}")
    unless File.exist?(scripts_path)
      Logging::Log.error "未找到脚本文件: #{scripts_path}"
      return
    end

    scripts = Marshal.load(File.binread(scripts_path))

    if index < 0 || index >= scripts.size
      Logging::Log.error "索引 #{index} 超出范围 (0-#{scripts.size - 1})"
      return
    end

    entry = scripts[index]
    code = Zlib::Inflate.inflate(entry[2])
    name = entry[1].dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")

    # 默认输出路径: 当前目录下的 index_name.rb
    unless output_path
      safe_name = name.gsub(/[^\w\u4e00-\u9fff]+/, '_').gsub(/_+/, '_').sub(/^_|_$/, '')
      safe_name = "script" if safe_name.empty?
      output_path = File.expand_path("#{format('%03d', index)}_#{safe_name}.rb")
    end

    File.binwrite(output_path, code)
    Logging::Log.result("#{format('%03d', index)}|#{name}|#{output_path}|#{code.size}")
  rescue => e
    Logging::Log.error "导出脚本失败: #{e.message}"
  end
  
  def parse_options
    OptionParser.new do |opts|
      opts.banner = "用法: RM-Toolkit.rb [选项]"
      opts.separator ""
      opts.separator "常规操作:"
      opts.on("-b", "--base-dir DIR", "指定基准目录 (默认: 当前目录)") { |d| @options[:base_dir] = d }
      opts.on("-u", "--unpack", "解包/解密模式") { @options[:unpack] = true }
      opts.on("-p", "--pack", "封包模式 (仅RGSS1/2/3)") { @options[:pack] = true }
      opts.on("-w", "--overwrite", "覆盖已存在的目标文件") { @options[:overwrite] = true }
      opts.on("--reconstruct", "重建项目结构 (解密前/解包后)") { @options[:reconstruct] = true }
      opts.on("--include-dirs DIRS", String, "在重建/解密时额外包含的顶级目录 (用逗号分隔)") do |dirs|
        @options[:include_dirs] = dirs.split(',').map(&:strip).reject(&:empty?)
      end
      
      opts.separator ""
      opts.separator "快照管理 (针对源码目录):"
      opts.on("--create-snapshot [NAME]", "为源码目录创建快照，可指定可选名称") do |name|
        @options[:snapshot_task] = :create
        @options[:snapshot_name] = name
      end
      opts.on("--list-snapshots", "列出所有可用的快照") { @options[:snapshot_task] = :list }
      opts.on("--restore-snapshot NAME", "从指定快照恢复源码目录") do |name|
        @options[:snapshot_task] = :restore
        @options[:snapshot_name] = name
      end
      opts.on("-f", "--force", "在恢复快照时跳过确认提示 (请谨慎使用)") { @options[:force_restore] = true }

      opts.separator ""
      opts.separator "脚本管理 (统一格式: 索引:参数):"
      opts.on("--list-scripts", "列出所有脚本的序号和名称 (独立运行)") { @options[:list_scripts] = true }
      opts.on("--create-script INDEX", Integer, "在指定序号创建空脚本，原序号后移 (仅 --pack)") { |i| @options[:script_create_index] = i }
      opts.on("--clear-script INDEX", Integer, "清空指定序号的脚本内容，保留位置和名称 (仅 --pack)") { |i| @options[:script_clear_index] = i }
      opts.on("--remove-script INDEX", Integer, "删除指定序号的脚本，后续前移 (仅 --pack)") { |i| @options[:remove_script] = i }
      opts.on("--prune-empty-scripts", "删除所有空脚本 (仅 --pack)") { @options[:prune_empty_scripts] = true }
      opts.on("--rename-script SPEC", String, "重命名脚本 (格式: 索引:新名称，仅 --pack)") do |spec|
        if spec =~ /\A(\d+):(.+)\z/
          @options[:script_rename] = [$1.to_i, $2]
        else
          raise OptionParser::InvalidArgument, "--rename-script 格式为 索引:新名称"
        end
      end
      opts.on("--move-script SPEC", String, "移动脚本位置 (格式: 源索引:目标索引，仅 --pack)") do |spec|
        if spec =~ /\A(\d+):(\d+)\z/
          @options[:script_move] = [$1.to_i, $2.to_i]
        else
          raise OptionParser::InvalidArgument, "--move-script 格式为 源索引:目标索引"
        end
      end
      opts.on("--scripts-only", "仅打包脚本，不处理其他数据文件") { @options[:scripts_only] = true }
      opts.on("--repack-scripts", "重新打包脚本（Source/scripts/ → Data/Scripts.*），等效于 --pack --scripts-only") { @options[:pack] = true; @options[:scripts_only] = true }
      opts.on("--inject-script SPEC", String, "注入脚本文件到指定序号，原序号后移 (可多次使用，格式: 索引:文件路径)") do |spec|
        if spec =~ /\A(\d+):(.+)\z/
          @options[:inject_scripts] << [$1.to_i, $2]
        else
          raise OptionParser::InvalidArgument, "--inject-script 格式为 索引:文件路径"
        end
      end
      opts.on("--replace-script SPEC", String, "替换指定序号的脚本内容 (可多次使用，格式: 索引:文件路径)") do |spec|
        if spec =~ /\A(\d+):(.+)\z/
          @options[:replace_scripts] << [$1.to_i, $2]
        else
          raise OptionParser::InvalidArgument, "--replace-script 格式为 索引:文件路径"
        end
      end
      opts.on("--export-script SPEC", String, "导出脚本到文件 (格式: 索引[:输出路径])") do |spec|
        if spec =~ /\A(\d+):(.+)\z/
          @options[:script_export] = [$1.to_i, $2]
        else
          @options[:script_export] = [spec.to_i, nil]
        end
      end
      opts.on("-e", "--extract-archive FILE", "独立提取RGSSAD存档并退出") { |f| @options[:extract_archive_path] = f }
      opts.on("-o", "--extract-output-dir DIR", "独立提取的输出目录") { |d| @options[:extract_output_path] = d }
      opts.on("--rgss1", "强制使用 RGSS1 (XP)") { @options[:rgss_version] = "RGSS1" }
      opts.on("--rgss2", "强制使用 RGSS2 (VX)") { @options[:rgss_version] = "RGSS2" }
      opts.on("--rgss3", "强制使用 RGSS3 (VX Ace)") { @options[:rgss_version] = "RGSS3" } # <--- BUG 修复
      opts.on("--mv", "强制使用 RPG Maker MV") { @options[:rgss_version] = "MV" }
      opts.on("--mz", "强制使用 RPG Maker MZ") { @options[:rgss_version] = "MZ" }
      opts.on("--log-level LEVEL", "设置日志级别 (DEBUG, INFO, WARN, ERROR)") { |l| @options[:log_level] = l.upcase }
      opts.on_tail("-h", "--help", "显示此帮助信息") { puts opts; exit }
    end.parse!(@argv)
  end

  def determine_base_directory
    # 使用 || 提供默认值，代码更简洁
    @base_dir = File.expand_path(@options[:base_dir] || Dir.pwd) # <--- 代码简化
    raise "基准目录不存在: #{@base_dir}" unless Dir.exist?(@base_dir)
  end
  
  def load_configuration
    config_loader = Configuration.new(@options[:config])
    @config = config_loader.load
  end
end