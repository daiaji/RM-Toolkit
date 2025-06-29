# lib/configuration.rb
# 负责加载和管理 YAML 配置文件

require "yaml"
require "pathname"
require_relative "logging"

class Configuration
  DEFAULT_CONFIG_FILENAME = "config.yaml".freeze

  # 默认配置项
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
      # --- 新增：自动快照默认配置 ---
      "auto_snapshot_after_rgss_unpack" => true,
      "auto_snapshot_after_mv_mz_reconstruct" => true,
    },
    "logging" => {
      "log_level" => "INFO",
      "log_to_file" => false,
      "log_directory" => "logs",
      "log_filename_format" => "rvdata2json_{timestamp}.log",
      "enable_colors" => true,
    },
  }.freeze

  attr_reader :path
  attr_reader :data

  def initialize(config_path_arg = nil)
    if config_path_arg
      @path = File.absolute_path?(config_path_arg) ? config_path_arg : File.expand_path(config_path_arg, Dir.pwd)
    else
      project_root = File.expand_path("..", __dir__)
      @path = File.join(project_root, DEFAULT_CONFIG_FILENAME)
    end
    @data = {}
  end

  def load
    loaded_data = {}
    if File.exist?(@path)
      begin
        loaded_data = YAML.load_file(@path) || {}
      rescue Psych::SyntaxError => e
        raise "配置文件 YAML 语法错误: #{e.message}"
      rescue => e
        raise "加载配置文件 '#{@path}' 时出错: #{e.class}: #{e.message}"
      end
    end

    @data = deep_merge(DEFAULT_CONFIG.dup, loaded_data)
    validate_config
    @data
  end

  def [](key)
    @data[key]
  end

  private

  def deep_merge(hash1, hash2)
    hash2.each do |key, value|
      if hash1.key?(key) && hash1[key].is_a?(Hash) && value.is_a?(Hash)
        deep_merge(hash1[key], value)
      elsif hash1.key?(key) && hash1[key].is_a?(Array) && value.is_a?(Array)
        hash1[key] = value
      else
        hash1[key] = value
      end
    end
    hash1
  end

  def validate_config
    valid_rgss_versions = %w[RGSS1 RGSS2 RGSS3 MV MZ].freeze
    raise "配置错误: 'rgss_version' 必须是 #{valid_rgss_versions.join(" 或 ")} 之一" unless valid_rgss_versions.include?(@data["rgss_version"])
    
    proj_struct = @data["project_structure"] || {}
    raise "配置错误: 'project_structure' 部分必须是一个哈希" unless proj_struct.is_a?(Hash)
    %w[game_data_dir source_data_dir].each do |key|
      raise "配置错误: 'project_structure.#{key}' 必须是字符串且非空" unless proj_struct[key].is_a?(String) && !proj_struct[key].empty?
    end
    raise "配置错误: 'project_structure.mv_mz_asset_dirs' 必须是一个数组" unless proj_struct["mv_mz_asset_dirs"].is_a?(Array)

    snapshot_config = @data["snapshot_options"] || {}
    raise "配置错误: 'snapshot_options' 部分必须是一个哈希" unless snapshot_config.is_a?(Hash)
    raise "配置错误: 'snapshot_options.directory' 必须是字符串" unless snapshot_config["directory"].is_a?(String)
    raise "配置错误: 'snapshot_options.format' 必须是字符串" unless snapshot_config["format"].is_a?(String)
    # --- 新增：自动快照配置验证 ---
    raise "配置错误: 'snapshot_options.auto_snapshot_after_rgss_unpack' 必须是 true 或 false" unless [true, false].include?(snapshot_config["auto_snapshot_after_rgss_unpack"])
    raise "配置错误: 'snapshot_options.auto_snapshot_after_mv_mz_reconstruct' 必须是 true 或 false" unless [true, false].include?(snapshot_config["auto_snapshot_after_mv_mz_reconstruct"])

    raise "配置错误: 'files' 必须是一个数组" unless @data["files"].is_a?(Array)
    raise "配置错误: 'exclude_files' 必须是一个数组" unless @data["exclude_files"].is_a?(Array)
    archive_config = @data["archive_processing"] || {}
    raise "配置错误: 'archive_processing' 部分必须是一个哈希" unless archive_config.is_a?(Hash)
    log_config = @data["logging"] || {}
    raise "配置错误: 'logging' 部分必须是一个哈希" unless log_config.is_a?(Hash)
  end
end