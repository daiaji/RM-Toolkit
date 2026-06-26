# lib/rgss_handler.rb
require 'find'
require_relative 'converter'
require_relative 'utils'
require_relative 'snapshot_manager'

class RgssHandler
  SCRIPTS_BASENAME = "scripts".freeze

  module ProjectGenerator
    RGSS_PROJECTS = {
      "RGSS1" => {
        file: "Game.rxproj",
        content: "RPGXP 1.05",
        ini_file: "Game.ini",
        ini_content: "[Game]\r\nLibrary=RGSS104E.dll\r\nScripts=Data\\Scripts.rxdata\r\nTitle=DecryptedProject\r\nRTP1=Standard\r\nRTP2=\r\nRTP3="
      },
      "RGSS2" => {
        file: "Game.rvproj",
        content: "RPGVX 1.02",
        ini_file: "Game.ini",
        ini_content: "[Game]\r\nRTP=RPGVX\r\nLibrary=RGSS202E.dll\r\nScripts=Data\\Scripts.rvdata\r\nTitle=DecryptedProject"
      },
      "RGSS3" => {
        file: "Game.rvproj2",
        content: "RPGVXAce 1.02",
        ini_file: "Game.ini",
        ini_content: "[Game]\r\nRTP=RPGVXAce\r\nLibrary=System\\RGSS300.dll\r\nScripts=Data\\Scripts.rvdata2\r\nTitle=DecryptedProject"
      },
    }.freeze
    
    def self.generate(base_dir, version, overwrite)
      config = RGSS_PROJECTS[version]
      return unless config
      
      project_path = File.join(base_dir, config[:file])
      if File.exist?(project_path) && !overwrite
        Logging::Log.warn "项目文件 #{config[:file]} 已存在于基准目录，跳过生成。使用 --overwrite 选项进行覆盖。"
      else
        File.write(project_path, config[:content])
        Logging::Log.info "成功在基准目录创建项目文件: #{project_path}"
      end
      
      ini_path = File.join(base_dir, config[:ini_file])
      if File.exist?(ini_path) && !overwrite
        Logging::Log.warn "配置文件 #{config[:ini_file]} 已存在于基准目录，跳过生成。使用 --overwrite 选项进行覆盖。"
      else
        File.write(ini_path, config[:ini_content])
        Logging::Log.info "成功在基准目录创建配置文件: #{ini_path}"
      end
    end
  end

  def initialize(options, config, version)
    @options, @config, @version = options, config, version
    @base_dir = @options[:base_dir]
    @archive_extracted_successfully = false
    @input_dir, @output_dir, @file_patterns, @exclude_patterns = nil, nil, [], []
  end

  def process
    Logging::Log.info "使用 RGSS 处理器处理版本: #{@version}"
    validate_operation
    setup_directories
    
    process_archive_extraction_if_needed
    process_project_reconstruction
    parse_config_patterns
    
    # 使用集中式加载器加载当前版本所需的类定义
    RPG::Loader.load(@version)
    
    files_processed = process_files
    
    if @options[:unpack] && files_processed > 0
      handle_auto_snapshot("rgss_unpack", "unpacked")
    end

    Logging::Log.info "RGSS 任务完成。"
  end
  
  private

  def validate_operation
    raise "错误: 对于 RGSS1/2/3 项目，必须指定 --unpack 或 --pack 中的一个。" unless @options[:unpack] ^ @options[:pack]
    if @options[:reconstruct] && @options[:pack]
      Logging::Log.warn "警告: --reconstruct 选项在 --pack 模式下无效，将被忽略。"
    end
  end
  
  def setup_directories
    structure_config = @config["project_structure"]
    game_data_dir_name = structure_config["game_data_dir"]
    source_data_dir_name = structure_config["source_data_dir"]

    if @options[:unpack]
      @input_dir = File.expand_path(game_data_dir_name, @base_dir)
      @output_dir = File.expand_path(source_data_dir_name, @base_dir)
    elsif @options[:pack]
      @input_dir = File.expand_path(source_data_dir_name, @base_dir)
      @output_dir = File.expand_path(game_data_dir_name, @base_dir)
    end
    
    Logging::Log.info "RGSS 输入目录: #{@input_dir}"
    Logging::Log.info "RGSS 输出目录: #{@output_dir}"
  end
  
  def process_archive_extraction_if_needed
    return unless @options[:unpack]
    archive_config = @config["archive_processing"]
    
    # 增加检查和日志
    unless archive_config["enabled"]
      Logging::Log.info "配置中已禁用存档提取功能，跳过。"
      return
    end
    
    unless defined?(RmToolkitNative)
      Logging::Log.warn "原生 C 扩展未加载，将跳过存档提取功能。请确认已成功编译扩展 (运行 `bundle exec rake compile`)。"
      return
    end

    archive_filename = archive_config["archive_filenames"][@version]
    return Logging::Log.warn("无法为版本 #{@version} 确定存档文件名，跳过提取。") unless archive_filename

    archive_path = File.join(@base_dir, archive_filename)
    return Logging::Log.info("未找到预期的存档文件 '#{archive_path}'，将直接处理输入目录 '#{@input_dir}'。") unless File.exist?(archive_path)

    Logging::Log.info "找到存档文件 '#{archive_filename}'，开始提取到基准目录 '#{@base_dir}'..."
    
    begin
      RmToolkitNative.extract_rgssad(archive_path, @base_dir, Logging::Log.debug?)
      Logging::Log.info "存档提取成功。"
      
      if archive_config["delete_archive_after_extraction"]
        Logging::Log.info "配置要求删除存档，尝试删除: #{archive_path}"
        FileUtils.rm(archive_path)
        Logging::Log.info "成功删除原始存档文件。"
      end
    rescue => e
      Logging::Log.error "存档提取失败: #{e.message}"
      raise if @options[:strict]
    end
  end

  def process_project_reconstruction
    return unless @options[:reconstruct] && @options[:unpack]
    Logging::Log.info "检测到 --reconstruct 选项，尝试为 #{@version} 在基准目录生成项目文件..."
    ProjectGenerator.generate(@base_dir, @version, @options[:overwrite])
  end

  def parse_config_patterns
    @file_patterns = (@config["files"] || []).map { |p| Regexp.new(p, Regexp::IGNORECASE) }
    @exclude_patterns = (@config["exclude_files"] || []).map { |p| Regexp.new(p, Regexp::IGNORECASE) }
  end

  def process_files
    file_list, input_ext, output_ext = get_file_list
    processed_count = 0

    if @options[:pack]
      scripts_source_dir = File.join(@input_dir, SCRIPTS_BASENAME)
      if Dir.exist?(scripts_source_dir)
        if @options[:remove_script]
          Converter::Scripts.remove_scripts(scripts_source_dir,
                                             remove_index: @options[:remove_script])
        end
        if @options[:prune_empty_scripts]
          Converter::Scripts.remove_scripts(scripts_source_dir,
                                             prune_empty: true)
        end
      end
      pack_scripts(output_ext)
      scripts_source_path_prefix = File.join(@input_dir, SCRIPTS_BASENAME).downcase
      file_list.reject! { |f| f.downcase.start_with?(scripts_source_path_prefix) }
    end
    
    return 0 if file_list.empty?

    exporter = @options[:unpack] ? Converter::JsonExporter.new(@version) : nil
    restorer = @options[:pack] ? Converter::RubyObjectRestorer.new(@version) : nil

    file_list.each do |input_file|
      if process_single_file(input_file, input_ext, output_ext, exporter, restorer)
        processed_count += 1
      end
    end
    
    processed_count
  end
  
  def get_file_list
    ext_map = {"RGSS1" => ".rxdata", "RGSS2" => ".rvdata", "RGSS3" => ".rvdata2"}
    rvdata_ext = ext_map[@version]
    source_ext = ".json"
    input_ext = @options[:unpack] ? rvdata_ext : source_ext
    output_ext = @options[:unpack] ? source_ext : rvdata_ext

    return [], input_ext, output_ext unless Dir.exist?(@input_dir)

    all_files = Find.find(@input_dir).select { |p| File.file?(p) && File.extname(p).downcase == input_ext.downcase }

    filtered = all_files.select do |f|
      begin
        rel_path = Pathname.new(f).relative_path_from(@input_dir).to_s
        base = rel_path.chomp(File.extname(rel_path))
        included = @file_patterns.any? { |re| base.match?(re) }
        excluded = @exclude_patterns.any? { |re| base.match?(re) }
        included && !excluded
      rescue ArgumentError
        false
      end
    end.uniq.sort
    
    Logging::Log.info "在 '#{@input_dir}' 中找到 #{filtered.size} 个匹配文件。"
    return filtered, input_ext, output_ext
  end

  def pack_scripts(output_ext)
    scripts_source_dir = File.join(@input_dir, SCRIPTS_BASENAME)
    return unless Dir.exist?(scripts_source_dir)
    
    output_file = File.join(@output_dir, SCRIPTS_BASENAME.capitalize + output_ext)
    Logging::Log.info "打包脚本: #{scripts_source_dir} -> #{File.basename(output_file)}"
    packed_array = Converter::Scripts.pack(scripts_source_dir)
    Converter::IO.write_marshal_data(output_file, packed_array)
  rescue => e
    Logging::Log.error "打包脚本失败: #{e.message}"
    raise if @options[:strict]
  end

  def process_single_file(input_file, input_ext, output_ext, exporter, restorer)
    log_basename = File.basename(input_file)
    begin
      rel_path = Pathname.new(input_file).relative_path_from(@input_dir).to_s
      output_file = File.join(@output_dir, rel_path.chomp(input_ext) + output_ext)
      
      if @options[:unpack]
        if File.basename(input_file, ".*").downcase == SCRIPTS_BASENAME
          Logging::Log.info "解包脚本: #{log_basename}"
          input_obj = Converter::IO.load_marshal_data(input_file)
          scripts_output_dir = File.join(@output_dir, SCRIPTS_BASENAME)
          Converter::Scripts.unpack(input_obj, scripts_output_dir)
        else
          Logging::Log.info "解包文件: #{log_basename}"
          input_obj = Converter::IO.load_marshal_data(input_file)
          cleaned_data = exporter.export(input_obj)
          Converter::IO.write_json_data(output_file, cleaned_data)
        end
      else # pack
        Logging::Log.info "封包文件: #{log_basename}"
        input_data = Converter::IO.load_json_data(input_file)
        restored_obj = restorer.restore(input_data)
        Converter::IO.write_marshal_data(output_file, restored_obj)
      end
      true
    rescue => e
      Logging::Log.error "处理文件 #{log_basename} 失败: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      raise if @options[:strict]
      false
    end
  end

  def handle_auto_snapshot(config_key, snapshot_auto_name)
    snapshot_config = @config["snapshot_options"]
    config_key_full = "auto_snapshot_after_#{config_key}"
    return unless snapshot_config[config_key_full]

    Logging::Log.info "配置已启用，将在操作后自动创建快照..."
    begin
      manager = SnapshotManager.new(@base_dir, @config)
      manager.create(auto_name: snapshot_auto_name)
    rescue => e
      Logging::Log.error "自动创建快照失败: #{e.message}"
    end
  end
end