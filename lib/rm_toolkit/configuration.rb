# lib/configuration.rb
# 负责加载和管理 YAML 配置文件，支持开发和部署环境

require 'yaml'
require 'pathname'
require 'fileutils' # 用于处理家目录路径
require_relative 'logging'

class Configuration
  # --- 配置文件的查找和命名 ---
  # 用户可以在这些位置创建自己的配置文件
  CONFIG_FILENAME = 'config.yaml'.freeze
  
  # 打包在 Gem 内部的默认配置文件名
  DEFAULT_CONFIG_FILENAME_IN_GEM = 'config.yaml'.freeze

  # 硬编码的默认配置，作为最终的保险措施
  DEFAULT_CONFIG = {
    "rgss_version" => "MZ",
    "project_structure" => {
      "game_data_dir" => "Data",
      "source_data_dir" => "Source",
      "mv_mz_asset_dirs" => [
        "audio", "css", "data", "effects", "fonts", 
        "icon", "img", "js", "movies"
      ],
    },
    "files" => [
      "Actors", "Animations", "Armors", "Classes", "CommonEvents",
      "Enemies", "Items", "MapInfos", "Scripts", "Skills", "States", "System",
      "Tilesets", "Troops", "Weapons", "Map\\d{3}",
    ],
    "exclude_files" => ["Areas"],
    "archive_processing" => {
      "enabled" => true,
      "archive_filenames" => {
        "RGSS1" => "Game.rgssad",
        "RGSS2" => "Game.rgss2a",
        "RGSS3" => "Game.rgss3a",
      },
      "delete_archive_after_extraction" => false,
    },
    "snapshot_options" => {
      "directory" => ".snapshots",
      "format" => "{dirname}_snapshot_{name}_{timestamp}",
      "auto_snapshot_after_rgss_unpack" => true,
    },
    "logging" => {
      "log_level" => "INFO",
      "log_to_file" => false,
      "log_directory" => "logs",
      "log_filename_format" => "RM-Toolkit_{timestamp}.log",
      "enable_colors" => true,
    },
  }.freeze

  attr_reader :path # 最终加载的用户配置文件的路径 (可能为 nil)
  attr_reader :data

  def initialize(config_path_arg = nil)
    # 查找用户配置文件的路径
    @path = find_config_file(config_path_arg)
    @data = {}
  end

  def load
    # 1. 从 Gem 内部加载默认配置作为基础
    gem_default_data = load_gem_default_config

    # 2. 如果找到了外部用户配置文件，加载它
    external_data = {}
    if @path && File.exist?(@path)
      begin
        external_data = YAML.load_file(@path) || {}
        # *** 已移除此处的 $stderr.puts 日志 ***
      rescue Psych::SyntaxError => e
        raise "配置文件 YAML 语法错误: #{e.message}"
      rescue => e
        raise "加载配置文件 '#{@path}' 时出错: #{e.class}: #{e.message}"
      end
    end

    # 3. 深度合并配置：用户配置 > Gem 内部默认配置
    @data = deep_merge(gem_default_data, external_data)

    validate_config
    @data
  end

  def [](key)
    @data[key]
  end

  private

  # 实现配置文件查找链
  def find_config_file(cli_path)
    # 1. 命令行指定的路径 (最高优先级)
    if cli_path
      path = File.expand_path(cli_path)
      # 立即返回路径，让 load 方法去检查文件是否存在
      return path
    end

    # 2. 当前工作目录
    current_dir_config = File.expand_path(CONFIG_FILENAME, Dir.pwd)
    return current_dir_config if File.exist?(current_dir_config)

    # 3. 用户家目录 (~/.config/rm-toolkit/config.yaml)
    begin
      home_config_dir = File.join(Dir.home, '.config', 'rm-toolkit')
      home_config_file = File.join(home_config_dir, CONFIG_FILENAME)
      return home_config_file if File.exist?(home_config_file)
    rescue ArgumentError # Dir.home 可能在某些受限环境下失败
      # 忽略错误，继续
    end
    
    # 如果以上都没找到，返回 nil
    nil
  end
  
  # 从 Gem 内部加载默认配置
  def load_gem_default_config
    project_root = find_project_root
    
    unless project_root
      $stderr.puts "[配置警告] 无法定位 Gem 根目录，将使用硬编码的默认配置。"
      return DEFAULT_CONFIG.dup
    end
    
    default_config_path = File.join(project_root, DEFAULT_CONFIG_FILENAME_IN_GEM)

    if File.exist?(default_config_path)
      YAML.load_file(default_config_path) || {}
    else
      $stderr.puts "[配置警告] 找不到打包在 Gem 内的默认配置文件: #{default_config_path}。将使用硬编码的默认配置。"
      DEFAULT_CONFIG.dup
    end
  end
  
  # 健壮地查找项目根目录（适用于开发和部署环境）
  def find_project_root
    # 优先使用 Gem API (适用于已安装的 Gem)
    spec = Gem.loaded_specs['rm-toolkit']
    return spec.full_gem_path if spec

    # 回退到向上查找 .gemspec (适用于本地开发)
    begin
      current_dir = Pathname.new(__dir__)
      while current_dir.parent != current_dir
        return current_dir.to_s if Dir.glob(current_dir.join('*.gemspec')).any?
        current_dir = current_dir.parent
      end
    rescue
      # 忽略任何可能的错误
    end
    
    nil # 如果所有方法都失败
  end

  # 递归合并两个哈希
  def deep_merge(hash1, hash2)
    hash2.each do |key, value|
      if hash1.key?(key) && hash1[key].is_a?(Hash) && value.is_a?(Hash)
        deep_merge(hash1[key], value)
      elsif hash1.key?(key) && hash1[key].is_a?(Array) && value.is_a?(Array)
        # 对于数组，让用户的配置完全替换默认配置
        hash1[key] = value
      else
        hash1[key] = value
      end
    end
    hash1
  end

  # 验证最终配置的有效性
  def validate_config
    valid_rgss_versions = %w[RGSS1 RGSS2 RGSS3 MV MZ].freeze
    unless valid_rgss_versions.include?(@data["rgss_version"])
      raise "配置错误: 'rgss_version' 必须是 #{valid_rgss_versions.join(", ")} 之一"
    end
    
    proj_struct = @data["project_structure"] || {}
    raise "配置错误: 'project_structure' 部分必须是一个哈希" unless proj_struct.is_a?(Hash)
    %w[game_data_dir source_data_dir].each do |key|
      unless proj_struct[key].is_a?(String) && !proj_struct[key].empty?
        raise "配置错误: 'project_structure.#{key}' 必须是一个非空的字符串"
      end
    end
    raise "配置错误: 'project_structure.mv_mz_asset_dirs' 必须是一个数组" unless proj_struct["mv_mz_asset_dirs"].is_a?(Array)

    snapshot_config = @data["snapshot_options"] || {}
    raise "配置错误: 'snapshot_options' 部分必须是一个哈希" unless snapshot_config.is_a?(Hash)
    raise "配置错误: 'snapshot_options.directory' 必须是一个字符串" unless snapshot_config["directory"].is_a?(String)
    raise "配置错误: 'snapshot_options.format' 必须是一个字符串" unless snapshot_config["format"].is_a?(String)
    unless [true, false].include?(snapshot_config["auto_snapshot_after_rgss_unpack"])
      raise "配置错误: 'snapshot_options.auto_snapshot_after_rgss_unpack' 必须是 true 或 false"
    end

    raise "配置错误: 'files' 必须是一个数组" unless @data["files"].is_a?(Array)
    raise "配置错误: 'exclude_files' 必须是一个数组" unless @data["exclude_files"].is_a?(Array)
    
    archive_config = @data["archive_processing"] || {}
    raise "配置错误: 'archive_processing' 部分必须是一个哈希" unless archive_config.is_a?(Hash)
    
    log_config = @data["logging"] || {}
    raise "配置错误: 'logging' 部分必须是一个哈希" unless log_config.is_a?(Hash)
  end
end