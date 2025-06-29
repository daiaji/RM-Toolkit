# lib/mv_mz_handler.rb
require 'json'
require 'find'
require 'fileutils'
require 'pathname'
require 'set' # 引入 Set 以提高查找效率
require_relative 'snapshot_manager'

class MvMzHandler
  # --- 项目重建模块 ---
  # 负责从发布的游戏目录中，智能地重建出一个可供编辑器打开的项目结构。
  module ProjectReconstructor
    MV_PROJECT_CONTENT = "RPGMV 1.6.3"
    MZ_PROJECT_CONTENT = "RPGMZ 1.8.0"
    
    # 白名单中的核心文件，这些文件总是需要被复制。
    BASE_FILES_WHITELIST = %w[index.html package.json].freeze

    # 重建项目结构
    # @param data_dir [String] 游戏数据文件所在的目录 (如 'www' 或 macOS 包内的 'app.nw')
    # @param output_dir [String] 重建后的项目输出目录
    # @param version [String] "MV" 或 "MZ"
    # @param overwrite [Boolean] 是否覆盖已存在的输出目录
    # @param dynamic_whitelist [Array<String>] 从配置加载的目录白名单 (如 ["audio", "img"])
    def self.reconstruct(data_dir, output_dir, version, overwrite, dynamic_whitelist)
      Logging::Log.info "开始为 RPG Maker #{version} 执行白名单智能重建到: #{output_dir}"

      # --- 关键修复：处理大小写敏感问题 ---
      # 1. 将配置中的白名单转换为小写的 Set，以便进行快速、不区分大小写的查找。
      whitelist_set = Set.new(dynamic_whitelist.map(&:downcase))
      Logging::Log.debug "已构建的白名单集合 (小写): #{whitelist_set.inspect}"
      # ------------------------------------

      extension_map = (version == "MV") ? MvMzHandler::MV_FILE_EXTENSIONS : MvMzHandler::MZ_FILE_EXTENSIONS
      encrypted_extensions = extension_map.keys.to_set

      # 处理输出目录
      if Dir.exist?(output_dir) && overwrite
        Logging::Log.info "覆盖模式开启，清空并重建输出目录: #{output_dir}"
        FileUtils.rm_rf(output_dir)
      end
      FileUtils.mkdir_p(output_dir)

      # --- 关键修复：遍历实际存在的目录，而不是硬编码的白名单 ---
      # 2. 获取源目录中实际存在的所有子目录。
      begin
        actual_subdirs = Dir.children(data_dir).select { |d| File.directory?(File.join(data_dir, d)) }
      rescue Errno::ENOENT
        Logging::Log.warn "警告: 源数据目录 '#{data_dir}' 不存在，无法进行重建。"
        actual_subdirs = []
      end
      
      # 3. 遍历实际存在的目录，并与白名单进行不区分大小写的比较。
      actual_subdirs.each do |dir_name|
        # 将实际目录名转为小写，然后检查是否在白名单 Set 中
        if whitelist_set.include?(dir_name.downcase)
          # 4. 如果匹配，使用原始大小写的 dir_name 进行复制。
          src_dir = File.join(data_dir, dir_name)
          dest_dir = File.join(output_dir, dir_name) # <-- 保留了原始大小写
          
          Logging::Log.debug "白名单匹配成功: '#{dir_name}', 将其复制到目标目录。"
          copy_directory_selectively(src_dir, dest_dir, encrypted_extensions)
        else
          Logging::Log.debug "目录 '#{dir_name}' 不在白名单中，已跳过。" if Logging::Log.debug?
        end
      end
      # -----------------------------------------------------------

      # 复制白名单中的基础文件
      BASE_FILES_WHITELIST.each do |file_name|
        src_file = File.join(data_dir, file_name)
        dest_file = File.join(output_dir, file_name)
        
        if File.exist?(src_file)
          FileUtils.cp(src_file, dest_file)
        end
      end

      # 创建项目文件
      project_file, content = (version == "MV") ? ["Game.rpgproject", MV_PROJECT_CONTENT] : ["game.rmmzproject", MZ_PROJECT_CONTENT]
      project_path = File.join(output_dir, project_file)
      File.write(project_path, content)
      
      Logging::Log.info "白名单智能重建完成。"
    end

    private

    # 选择性地复制目录内容，跳过指定的加密文件扩展名
    def self.copy_directory_selectively(source_dir, dest_dir, extensions_to_skip)
      FileUtils.mkdir_p(dest_dir)

      Dir.foreach(source_dir) do |entry|
        next if entry == '.' || entry == '..'
        
        full_source_path = File.join(source_dir, entry)
        full_dest_path = File.join(dest_dir, entry)
        
        if File.directory?(full_source_path)
          # 递归复制子目录
          copy_directory_selectively(full_source_path, full_dest_path, extensions_to_skip)
        elsif File.file?(full_source_path)
          # 仅复制不在跳过列表中的文件
          unless extensions_to_skip.include?(File.extname(full_source_path))
            FileUtils.cp(full_source_path, full_dest_path)
          end
        end
      end
    end
  end

  # 定义常量
  MV_FILE_EXTENSIONS = { ".rpgmvo" => ".ogg", ".rpgmvp" => ".png", ".rpgmvm" => ".m4a" }.freeze
  MZ_FILE_EXTENSIONS = { ".ogg_" => ".ogg", ".png_" => ".png", ".m4a_" => ".m4a" }.freeze
  MACOS_BUNDLE_PATH = File.join("Contents", "Resources", "app.nw").freeze

  def initialize(options, config, version)
    @options, @config, @version = options, config, version
    @base_dir = @options[:base_dir]
    
    structure_config = @config["project_structure"]
    config_whitelist = structure_config["mv_mz_asset_dirs"]
    
    # 动态白名单现在由配置和命令行参数共同决定
    @dynamic_dir_whitelist = (config_whitelist + @options[:include_dirs]).uniq
  end

  def process
    validate_operation
    data_dir = find_data_directory
    
    output_dir_name = @config["project_structure"]["source_data_dir"]
    output_dir = File.expand_path(output_dir_name, @base_dir)

    key = find_encryption_key(data_dir)

    if key.nil?
      Logging::Log.error("获取加密密钥失败，无法继续。")
      raise "加密密钥获取失败" if @options[:strict]
      return
    end

    if @options[:reconstruct]
      ProjectReconstructor.reconstruct(data_dir, output_dir, @version, @options[:overwrite], @dynamic_dir_whitelist)
      update_system_json_encryption_flags(output_dir)
      
      # 在重建成功后触发自动快照
      handle_auto_snapshot("mv_mz_reconstruct", "reconstructed")
    end

    if key != :no_encryption
      decrypt_all_files(data_dir, output_dir, key)
    else
      Logging::Log.info("项目文件未加密，无需执行解密操作。")
    end
    
    Logging::Log.info "MV/MZ 处理完成。"
  end
  
  private

  # 验证操作是否适用于 MV/MZ
  def validate_operation
    raise "错误: RPG Maker #{@version} 项目只支持 --unpack (解密/重建) 操作。" unless @options[:unpack]
    if @options[:pack]
      Logging::Log.warn "警告: --pack 选项对 #{@version} 项目无效，将被忽略。"
    end
  end
  
  # 查找包含核心游戏数据的目录
  def find_data_directory
    # 处理 macOS .app 包
    mac_app_dir = Dir.glob(File.join(@base_dir, "*.app")).first
    if mac_app_dir
      potential_path = File.join(mac_app_dir, MACOS_BUNDLE_PATH)
      return potential_path if Dir.exist?(potential_path)
    end
    
    # MV 项目通常有一个 'www' 目录
    if @version == "MV"
      www_dir = File.join(@base_dir, "www")
      return www_dir if Dir.exist?(www_dir)
    end
    
    # 默认情况 (如 Windows/Linux 的 MZ 项目)
    @base_dir
  end
  
  # 从 System.json 中查找加密密钥
  def find_encryption_key(data_dir)
    system_json_path = File.join(data_dir, "data", "System.json")
    return :no_encryption unless File.exist?(system_json_path)
    
    begin
      json_content = JSON.parse(File.read(system_json_path))
      key_hash = json_content["encryptionKey"]
      
      # 如果没有密钥或密钥为空，则认为未加密
      return :no_encryption if key_hash.nil? || key_hash.empty?
      
      # 密钥必须是32位的十六进制字符串 (MD5)
      return nil if key_hash.length != 32
      
      # 将十六进制字符串转换为16字节的二进制密钥
      [key_hash].pack('H*')
    rescue JSON::ParserError => e
      Logging::Log.error "解析 System.json 失败: #{e.message}"
      raise if @options[:strict]
      nil
    end
  end
  
  # 在重建的项目中更新 System.json，移除加密标志
  def update_system_json_encryption_flags(project_dir)
    system_json_path = File.join(project_dir, "data", "System.json")
    
    return Logging::Log.warn("警告: 在重建的项目目录中找不到 System.json，无法更新加密标志。") unless File.exist?(system_json_path)
    
    begin
      require 'oj' unless defined?(Oj) # 使用 Oj 以保留原始 JSON 结构
      
      json_string = File.read(system_json_path)
      data = Oj.load(json_string, mode: :compat)
      
      needs_update = false
      if data["hasEncryptedImages"] == true
        data["hasEncryptedImages"] = false
        needs_update = true
      end
      
      if data["hasEncryptedAudio"] == true
        data["hasEncryptedAudio"] = false
        needs_update = true
      end
      
      if needs_update
        # 使用 Oj 美化输出，便于阅读和版本控制
        updated_json_string = Oj.dump(data, mode: :compat, indent: 2)
        File.write(system_json_path, updated_json_string, encoding: 'UTF-8')
        Logging::Log.info "已更新 #{File.basename(system_json_path)}: 将加密标志 (hasEncryptedImages/Audio) 设置为 false。"
      else
        Logging::Log.info "#{File.basename(system_json_path)} 中的加密标志已经是 false，无需更新。"
      end
      
    rescue JSON::ParserError => e
      Logging::Log.error "处理 #{system_json_path} 时发生 JSON 错误: #{e.message}"
    rescue => e
      Logging::Log.error "更新 #{system_json_path} 时发生未知错误: #{e.message}"
    end
  end

  # 解密所有在白名单目录中的加密文件
  def decrypt_all_files(source_dir, output_root_dir, key)
    extension_map = (@version == "MV") ? MV_FILE_EXTENSIONS : MZ_FILE_EXTENSIONS
    Logging::Log.info "开始在 '#{source_dir}' 的白名单目录中扫描加密文件，解密到 '#{output_root_dir}'..."

    @dynamic_dir_whitelist.each do |dir_name|
      scan_dir = File.join(source_dir, dir_name)
      next unless Dir.exist?(scan_dir)

      Find.find(scan_dir) do |path|
        next unless File.file?(path)
        
        ext = File.extname(path)
        next unless extension_map.key?(ext)
        
        # 计算相对路径，以便在输出目录中保持相同的结构
        relative_path = Pathname.new(path).relative_path_from(source_dir).to_s
        new_ext = extension_map[ext]
        output_file_path = File.join(output_root_dir, relative_path.sub(/#{Regexp.escape(ext)}$/, new_ext))

        next if File.exist?(output_file_path) && !@options[:overwrite]
        
        FileUtils.mkdir_p(File.dirname(output_file_path))
        Logging::Log.info "解密: #{relative_path}"
        
        begin
          # 调用 C 扩展进行解密
          RpgMakerTools.decrypt_mv_mz(path, output_file_path, key)
        rescue => e
          Logging::Log.error "解密文件 '#{relative_path}' 失败: #{e.message}"
          raise if @options[:strict]
        end
      end
    end
  end

  # 处理自动快照创建
  def handle_auto_snapshot(config_key, snapshot_auto_name)
    snapshot_config = @config["snapshot_options"]
    config_key_full = "auto_snapshot_after_#{config_key}"
    return unless snapshot_config[config_key_full]

    Logging::Log.info "配置已启用，将在操作后自动创建快照..."
    begin
      manager = SnapshotManager.new(@base_dir, @config)
      manager.create(nil, auto_name: snapshot_auto_name)
    rescue => e
      Logging::Log.error "自动创建快照失败: #{e.message}"
      # 不中止程序，因为核心操作已完成
    end
  end
end