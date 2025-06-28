# lib/rgss_handler.rb
require_relative 'converter'
require_relative 'utils'

class RgssHandler
  SCRIPTS_BASENAME = "scripts".freeze

  module ProjectGenerator
    RGSS_PROJECTS = {
      "RGSS1" => { file: "Game.rxproj", content: "RPGXP 1.05" },
      "RGSS2" => { file: "Game.rvproj", content: "RPGVX 1.02" },
      "RGSS3" => { file: "Game.rvproj2", content: "RPGVXAce 1.02" },
    }.freeze
    
    def self.generate(output_dir, version, overwrite)
      config = RGSS_PROJECTS[version]
      return unless config
      
      project_path = File.join(output_dir, config[:file])
      if File.exist?(project_path) && !overwrite
        Logging::Log.warn "项目文件 #{config[:file]} 已存在，跳过生成。使用 --overwrite 选项进行覆盖。"
        return
      end
      
      File.write(project_path, config[:content])
      Logging::Log.info "成功创建项目文件: #{project_path}"
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
    process_archive_extraction
    process_project_reconstruction
    parse_config_patterns
    load_rgss_module
    adjust_input_directory_for_unpack
    process_files
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
    input_dir_key = @options[:unpack] ? "input_dir_marshal" : "input_dir_source"
    output_dir_key = @options[:unpack] ? "output_dir_source" : "output_dir_marshal"
    @input_dir = File.expand_path(@config[input_dir_key], @base_dir)
    @output_dir = File.expand_path(@config[output_dir_key], @base_dir)
    Logging::Log.info "RGSS 输入目录 (初始): #{@input_dir}"
    Logging::Log.info "RGSS 输出目录: #{@output_dir}"
  end
  
  def process_archive_extraction
    return unless @options[:unpack]
    archive_config = @config["archive_processing"]
    return unless archive_config["enabled"] && defined?(RpgMakerTools)

    archive_filename = archive_config["archive_filenames"][@version]
    return Logging::Log.warn("无法为版本 #{@version} 确定存档文件名，跳过提取。") unless archive_filename

    archive_path = File.join(@base_dir, archive_filename)
    return Logging::Log.info("未找到预期的存档文件 '#{archive_path}'，跳过提取。") unless File.exist?(archive_path)

    Logging::Log.info "找到存档文件 '#{archive_filename}'，开始提取到基准目录 '#{@base_dir}'..."
    
    begin
      RpgMakerTools.extract_rgssad(archive_path, @base_dir, Logging::Log.debug?)
      @archive_extracted_successfully = true
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
    Logging::Log.info "检测到 --reconstruct 选项，尝试为 #{@version} 生成项目文件..."
    ProjectGenerator.generate(@output_dir, @version, @options[:overwrite])
  end

  def parse_config_patterns
    @file_patterns = (@config["files"] || []).map { |p| Regexp.new(p, Regexp::IGNORECASE) }
    @exclude_patterns = (@config["exclude_files"] || []).map { |p| Regexp.new(p, Regexp::IGNORECASE) }
  end

  def load_rgss_module
    require_relative @version.downcase
  end

  def adjust_input_directory_for_unpack
    return unless @options[:unpack]
    return unless @config["archive_processing"]["enabled"]
    
    if @archive_extracted_successfully
      Logging::Log.info "将使用基准目录 '#{@base_dir}' 作为存档提取后的输入源。"
      @input_dir = @base_dir
    else
      Logging::Log.warn "存档提取未成功/未执行，将使用原始输入目录 '#{@input_dir}'。"
      raise "错误: 存档提取失败/未执行，且原始输入目录 '#{@input_dir}' 也不存在。" unless Dir.exist?(@input_dir)
    end
  end

  def process_files
    file_list, input_ext, output_ext = get_file_list

    if @options[:pack]
      pack_scripts(output_ext)
      scripts_rel_path = Pathname.new(File.join(@config["input_dir_source"], SCRIPTS_BASENAME)).relative_path_from(@base_dir).to_s.downcase
      file_list.reject! { |f| Pathname.new(f).relative_path_from(@base_dir).to_s.downcase.start_with?(scripts_rel_path) }
    end
    
    return Logging::Log.info "未找到匹配文件进行处理。" if file_list.empty?

    exporter = @options[:unpack] ? Converter::JsonExporter.new(@version) : nil
    restorer = @options[:pack] ? Converter::RvdataRestorer.new(@version) : nil

    file_list.each do |input_file|
      process_single_file(input_file, input_ext, output_ext, exporter, restorer)
    end
  end
  
  def get_file_list
    ext_map = {"RGSS1" => ".rxdata", "RGSS2" => ".rvdata", "RGSS3" => ".rvdata2"}
    rvdata_ext = ext_map[@version]
    source_ext = ".json"
    input_ext = @options[:unpack] ? rvdata_ext : source_ext
    output_ext = @options[:unpack] ? source_ext : rvdata_ext

    Logging::Log.info "在目录 #{@input_dir} 中搜索 *#{input_ext} 文件..."
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
    
    Logging::Log.info "找到 #{filtered.size} 个匹配文件。"
    return filtered, input_ext, output_ext
  end

  def pack_scripts(output_ext)
    scripts_source_dir = File.expand_path(File.join(@config["input_dir_source"], SCRIPTS_BASENAME), @base_dir)
    return unless Dir.exist?(scripts_source_dir)
    
    output_file = File.join(@output_dir, SCRIPTS_BASENAME.capitalize + output_ext)
    Logging::Log.info "检测到脚本源目录，打包: #{scripts_source_dir} -> #{File.basename(output_file)}"
    packed_array = Converter::Scripts.pack(scripts_source_dir)
    Converter::IO.write_marshal_data(output_file, packed_array)
  rescue => e
    Logging::Log.error "打包脚本失败: #{e.message}"
    raise if @options[:strict]
  end

  def process_single_file(input_file, input_ext, output_ext, exporter, restorer)
    log_basename = File.basename(input_file)
    begin
      if @options[:unpack]
        if input_file.downcase.end_with?("scripts#{input_ext}")
          Logging::Log.info "解包 #{log_basename} -> 脚本文件..."
          input_obj = Converter::IO.load_marshal_data(input_file)
          scripts_output_dir = File.join(@output_dir, SCRIPTS_BASENAME)
          Converter::Scripts.unpack(input_obj, scripts_output_dir)
        else
          Logging::Log.info "解包 #{log_basename} -> JSON..."
          input_obj = Converter::IO.load_marshal_data(input_file)
          cleaned_data = exporter.export(input_obj)
          rel_path = Pathname.new(input_file).relative_path_from(@input_dir).to_s
          output_file = File.join(@output_dir, rel_path.chomp(input_ext) + output_ext)
          Converter::IO.write_json_data(output_file, cleaned_data)
        end
      else # pack
        Logging::Log.info "封包 #{log_basename} -> RVData/RXData..."
        input_data = Converter::IO.load_json_data(input_file)
        restored_obj = restorer.restore(input_data)
        rel_path = Pathname.new(input_file).relative_path_from(@input_dir).to_s
        output_file = File.join(@output_dir, rel_path.chomp(input_ext) + output_ext)
        Converter::IO.write_marshal_data(output_file, restored_obj)
      end
    rescue => e
      Logging::Log.error "处理文件 #{log_basename} 失败: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      raise if @options[:strict]
    end
  end
end