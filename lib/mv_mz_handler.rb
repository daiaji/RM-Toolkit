# lib/mv_mz_handler.rb
require 'json'
require 'find'
require 'fileutils'
require 'pathname'

class MvMzHandler
  # --- 内部模块：项目重建器 (采用“白名单 + 智能复制”策略) ---
  module ProjectReconstructor
    MV_PROJECT_CONTENT = "RPGMV 1.6.3"
    MZ_PROJECT_CONTENT = "RPGMZ 1.8.0"
    
    # 基础白名单
    BASE_DIRECTORIES_WHITELIST = %w[audio css data effects fonts icon img js movies].freeze
    BASE_FILES_WHITELIST = %w[index.html package.json].freeze

    # 智能重建的核心方法，现在接收一个动态的白名单
    def self.reconstruct(data_dir, output_dir, version, overwrite, dynamic_whitelist)
      Logging::Log.info "开始为 RPG Maker #{version} 执行白名单智能重建到: #{output_dir}"
      Logging::Log.info "动态白名单: #{dynamic_whitelist.inspect}"

      extension_map = (version == "MV") ? MvMzHandler::MV_FILE_EXTENSIONS : MvMzHandler::MZ_FILE_EXTENSIONS
      encrypted_extensions = extension_map.keys.to_set

      if Dir.exist?(output_dir) && overwrite
        Logging::Log.info "覆盖模式开启，清空并重建输出目录: #{output_dir}"
        FileUtils.rm_rf(output_dir)
      end
      FileUtils.mkdir_p(output_dir)

      # 1. 复制动态白名单中的顶级目录
      dynamic_whitelist.each do |dir_name|
        src_dir = File.join(data_dir, dir_name)
        dest_dir = File.join(output_dir, dir_name)
        
        if Dir.exist?(src_dir)
          Logging::Log.debug "处理白名单目录: #{dir_name}" if Logging::Log.debug?
          copy_directory_selectively(src_dir, dest_dir, encrypted_extensions)
        else
          Logging::Log.warn "警告: 白名单目录 '#{dir_name}' 在源目录中不存在，已跳过。"
        end
      end
      
      # 2. 复制固定的顶级文件白名单
      BASE_FILES_WHITELIST.each do |file_name|
        src_file = File.join(data_dir, file_name)
        dest_file = File.join(output_dir, file_name)
        
        if File.exist?(src_file)
          FileUtils.cp(src_file, dest_file)
        end
      end

      # 3. 创建项目文件
      project_file, content = (version == "MV") ? ["Game.rpgproject", MV_PROJECT_CONTENT] : ["game.rmmzproject", MZ_PROJECT_CONTENT]
      project_path = File.join(output_dir, project_file)
      File.write(project_path, content)
      
      Logging::Log.info "白名单智能重建完成。"
    end

    private

    # 递归地、有选择性地复制目录内容
    def self.copy_directory_selectively(source_dir, dest_dir, extensions_to_skip)
      FileUtils.mkdir_p(dest_dir)

      Dir.foreach(source_dir) do |entry|
        next if entry == '.' || entry == '..'
        
        full_source_path = File.join(source_dir, entry)
        full_dest_path = File.join(dest_dir, entry)
        
        if File.directory?(full_source_path)
          copy_directory_selectively(full_source_path, full_dest_path, extensions_to_skip)
        elsif File.file?(full_source_path)
          unless extensions_to_skip.include?(File.extname(full_source_path))
            FileUtils.cp(full_source_path, full_dest_path)
          end
        end
      end
    end
  end

  # --- 常量定义 ---
  MV_FILE_EXTENSIONS = { ".rpgmvo" => ".ogg", ".rpgmvp" => ".png", ".rpgmvm" => ".m4a" }
  MZ_FILE_EXTENSIONS = { ".ogg_" => ".ogg", ".png_" => ".png", ".m4a_" => ".m4a" }
  MACOS_BUNDLE_PATH = File.join("Contents", "Resources", "app.nw")

  def initialize(options, config, version)
    @options, @config, @version = options, config, version
    @base_dir = @options[:base_dir]
    # 在这里合并基础白名单和用户自定义白名单
    @dynamic_dir_whitelist = (ProjectReconstructor::BASE_DIRECTORIES_WHITELIST + @options[:include_dirs]).uniq
  end

  # --- 主处理流程 ---
  def process
    validate_operation
    data_dir = find_data_directory
    output_dir = File.expand_path(@config["output_dir_source"], @base_dir)
    key = find_encryption_key(data_dir)

    if key.nil?
      Logging::Log.error("获取加密密钥失败，无法继续。")
      raise "加密密钥获取失败" if @options[:strict]
      return
    end

    if @options[:reconstruct]
      # 将动态白名单传递给重建器
      ProjectReconstructor.reconstruct(data_dir, output_dir, @version, @options[:overwrite], @dynamic_dir_whitelist)
      update_system_json_encryption_flags(output_dir)
    end

    if key != :no_encryption
      decrypt_all_files(data_dir, output_dir, key)
    else
      Logging::Log.info("项目文件未加密，无需执行解密操作。")
    end
    
    Logging::Log.info "MV/MZ 处理完成。"
  end
  
  private

  def validate_operation
    raise "错误: RPG Maker #{@version} 项目只支持 --unpack (解密/重建) 操作。" unless @options[:unpack]
    if @options[:pack]
      Logging::Log.warn "警告: --pack 选项对 #{@version} 项目无效，将被忽略。"
    end
  end
  
  def find_data_directory
    mac_app_dir = Dir.glob(File.join(@base_dir, "*.app")).first
    if mac_app_dir
      potential_path = File.join(mac_app_dir, MACOS_BUNDLE_PATH)
      return potential_path if Dir.exist?(potential_path)
    end
    if @version == "MV"
      www_dir = File.join(@base_dir, "www")
      return www_dir if Dir.exist?(www_dir)
    end
    @base_dir
  end
  
  def find_encryption_key(data_dir)
    system_json_path = File.join(data_dir, "data", "System.json")
    return :no_encryption unless File.exist?(system_json_path)
    
    begin
      json_content = JSON.parse(File.read(system_json_path))
      key_hash = json_content["encryptionKey"]
      
      return :no_encryption if key_hash.nil? || key_hash.empty?
      return nil if key_hash.length != 32
      
      [key_hash].pack('H*')
    rescue JSON::ParserError => e
      Logging::Log.error "解析 System.json 失败: #{e.message}"
      raise if @options[:strict]
      nil
    end
  end
  
  def update_system_json_encryption_flags(project_dir)
    system_json_path = File.join(project_dir, "data", "System.json")
    
    unless File.exist?(system_json_path)
      Logging::Log.warn "警告: 在重建的项目目录中找不到 System.json，无法更新加密标志。"
      return
    end
    
    begin
      require 'oj' unless defined?(Oj)
      
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
        updated_json_string = Oj.dump(data, mode: :compat, indent: 2)
        File.write(system_json_path, updated_json_string)
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

  # 核心解密函数，现在也使用动态白名单
  def decrypt_all_files(source_dir, output_root_dir, key)
    extension_map = (@version == "MV") ? MV_FILE_EXTENSIONS : MZ_FILE_EXTENSIONS
    Logging::Log.info "开始在 '#{source_dir}' 的白名单目录中扫描加密文件，解密到 '#{output_root_dir}'..."

    # 使用 @dynamic_dir_whitelist 进行遍历
    @dynamic_dir_whitelist.each do |dir_name|
      scan_dir = File.join(source_dir, dir_name)
      next unless Dir.exist?(scan_dir)

      Find.find(scan_dir) do |path|
        next unless File.file?(path)
        
        ext = File.extname(path)
        next unless extension_map.key?(ext)
        
        relative_path = Pathname.new(path).relative_path_from(source_dir).to_s
        new_ext = extension_map[ext]
        output_file_path = File.join(output_root_dir, relative_path.sub(/#{Regexp.escape(ext)}$/, new_ext))

        if File.exist?(output_file_path) && !@options[:overwrite]
          Logging::Log.warn "  跳过: 输出文件 #{File.basename(output_file_path)} 已存在。使用 --overwrite。"
          next
        end
        
        FileUtils.mkdir_p(File.dirname(output_file_path))
        Logging::Log.info "  解密: #{relative_path}"
        
        begin
          RpgMakerTools.decrypt_mv_mz(path, output_file_path, key)
        rescue => e
          Logging::Log.error "    解密文件失败: #{e.message}"
          raise if @options[:strict]
        end
      end
    end
  end
end