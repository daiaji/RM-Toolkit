# lib/application.rb
require 'optparse'
require 'pathname'
require 'fileutils'

# 提前加载，确保 C 扩展路径设置正确
lib_path = File.expand_path(__dir__)
# extconf.rb 指定了 'rpg_maker_tools/rpg_maker_tools'，所以需要 'ext' 目录在路径中
ext_path = File.expand_path(File.join(__dir__, '..', 'ext'))
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
$LOAD_PATH.unshift(ext_path) unless $LOAD_PATH.include?(ext_path)

# 尝试加载 C 扩展
begin
  require "rpg_maker_tools/rpg_maker_tools"
  NATIVE_TOOLS_LOADED = true
rescue LoadError => e
  NATIVE_TOOLS_LOADED = false
end

require_relative 'logging'
require_relative 'configuration'
require_relative 'version_detector'
require_relative 'rgss_handler'
require_relative 'mv_mz_handler'

class Application
  RGSS_VERSIONS = %w[RGSS1 RGSS2 RGSS3 MV MZ].freeze
  DEFAULT_STANDALONE_EXTRACT_DIR = "extracted_archive".freeze

  def initialize(argv)
    @argv = argv
    @options = {
      config: nil, base_dir: nil, log_level: nil, log_dir: nil,
      unpack: false, pack: false, overwrite: false, reconstruct: false, strict: false,
      rgss_version: nil, extract_archive_path: nil, extract_output_path: nil,
      include_dirs: [] # 新增：初始化为空数组
    }
    @base_dir = nil
    @config = nil
  end

  def run
    parse_options
    determine_base_directory
    load_configuration
    Logging.setup_logger(@config, @base_dir, @options[:log_level], @options[:log_dir])
    
    if @options[:extract_archive_path]
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
  
  def handle_standalone_extraction
    raise "错误: 独立存档提取模式需要原生工具 C 扩展，但加载失败。" unless NATIVE_TOOLS_LOADED
    Logging::Log.info "进入独立存档提取模式..."
    
    input_path = File.expand_path(@options[:extract_archive_path], @base_dir)
    output_path = @options[:extract_output_path] ? File.expand_path(@options[:extract_output_path]) : File.expand_path(DEFAULT_STANDALONE_EXTRACT_DIR, Dir.pwd)
    
    FileUtils.mkdir_p(output_path)
    RpgMakerTools.extract_rgssad(input_path, output_path, Logging::Log.debug?)
    Logging::Log.info "存档已提取到: #{output_path}"
  end
  
  def handle_regular_processing
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
  
  def parse_options
    OptionParser.new do |opts|
      opts.banner = "用法: rvdata2json.rb [选项]"
      opts.on("-b", "--base-dir DIR", "指定基准目录 (默认: 当前目录)") { |d| @options[:base_dir] = d }
      opts.on("-u", "--unpack", "解包/解密模式") { @options[:unpack] = true }
      opts.on("-p", "--pack", "封包模式 (仅RGSS1/2/3)") { @options[:pack] = true }
      opts.on("-w", "--overwrite", "覆盖已存在的目标文件") { @options[:overwrite] = true }
      opts.on("--reconstruct", "重建项目结构 (解密前/解包后)") { @options[:reconstruct] = true }
      
      # 新增参数定义
      opts.on("--include-dirs DIRS", String, "在重建/解密时额外包含的顶级目录 (用逗号分隔)",
                                             "  例如: --include-dirs mods,extra_assets") do |dirs|
        @options[:include_dirs] = dirs.split(',').map(&:strip).reject(&:empty?)
      end
      
      opts.on("--strict", "启用严格模式，遇到第一个文件错误即中止") { @options[:strict] = true }
      opts.on("-e", "--extract-archive FILE", "独立提取RGSSAD存档并退出") { |f| @options[:extract_archive_path] = f }
      opts.on("-o", "--extract-output-dir DIR", "独立提取的输出目录") { |d| @options[:extract_output_path] = d }
      opts.on("--rgss1", "强制使用 RGSS1 (XP)") { @options[:rgss_version] = "RGSS1" }
      opts.on("--rgss2", "强制使用 RGSS2 (VX)") { @options[:rgss_version] = "RGSS2" }
      opts.on("--rgss3", "强制使用 RGSS3 (VX Ace)") { @options[:rgss_version] = "RGSS3" }
      opts.on("--mv", "强制使用 RPG Maker MV") { @options[:rgss_version] = "MV" }
      opts.on("--mz", "强制使用 RPG Maker MZ") { @options[:rgss_version] = "MZ" }
      opts.on("--log-level LEVEL", "设置日志级别 (DEBUG, INFO, WARN, ERROR)") { |l| @options[:log_level] = l.upcase }
      opts.on_tail("-h", "--help", "显示此帮助信息") { puts opts; exit }
    end.parse!(@argv)
  end

  def determine_base_directory
    @base_dir = @options[:base_dir] ? File.expand_path(@options[:base_dir]) : Dir.pwd
    raise "基准目录不存在: #{@base_dir}" unless Dir.exist?(@base_dir)
  end
  
  def load_configuration
    config_loader = Configuration.new(@options[:config])
    @config = config_loader.load
  end
end