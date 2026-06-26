# 包含核心的 RVData/RXData <-> JSON 转换逻辑

require 'oj'        # 用于快速 JSON 解析和生成
require 'fileutils' # 用于文件操作，如创建目录
require 'set'       # 用于高效地处理已访问对象集合
require 'zlib'      # 用于处理 Scripts.rvdata 中的压缩脚本

# Logging 模块应已加载 (通过 application.rb 或直接 require)
# require_relative 'logging' # 如果需要独立运行此文件，则取消注释

module Converter

  # --- 输入/输出 模块 ---
  # 处理文件的加载和写入操作
  module IO
    # 从磁盘加载 Marshal (RVData/RXData) 文件
    # @param input_file [String] 输入文件路径
    # @return [Object] 反序列化后的 Ruby 对象
    # @raise [NameError] 如果遇到未定义的类/模块 (通常是 RGSS 版本不匹配)
    # @raise [ArgumentError] 如果文件损坏或版本不匹配
    # @raise [TypeError] 如果类型错误 (通常是 RGSS 版本不匹配)
    # @raise [RuntimeError] 如果发生其他读写或解析错误
    def self.load_marshal_data(input_file)
      file_basename = File.basename(input_file)
      Logging::Log.debug "加载 Marshal 数据: #{file_basename}" if Logging::Log.debug?
      begin
        # 以二进制读取模式打开文件并加载 Marshal 数据
        File.open(input_file, "rb") { |f| Marshal.load(f) }
      rescue ArgumentError => e
        # 处理 Marshal.load 可能抛出的 ArgumentError
        if e.message.include?("undefined class/module") || e.message.include?("allocator is not defined")
          # 明确是类/模块未定义错误
          err_msg = "加载 Marshal 数据 '#{file_basename}' 出错: #{e.message}。请确保加载了正确的 RGSS 定义 (rgss1/2/3.rb)。"
          Logging::Log.error err_msg
          # 抛出 NameError 更符合 Ruby 语义
          raise NameError, err_msg, caller
        else
          # 其他 ArgumentError，可能是文件损坏或版本不匹配
          err_msg = "加载 Marshal 数据 '#{file_basename}' 时发生参数错误 (可能是版本不匹配或文件损坏): #{e.message}"
          Logging::Log.error err_msg
          raise ArgumentError, err_msg
        end
      rescue TypeError => e
        # 处理类型错误，通常也与 RGSS 定义有关
        err_msg = "加载 Marshal 数据 '#{file_basename}' 时发生类型错误 (请确保加载了正确的 RGSS 定义): #{e.message}"
        Logging::Log.error err_msg
        raise TypeError, err_msg
      rescue => e
        # 捕获其他所有可能的异常 (文件读写、未知解析错误等)
        err_msg = "读取或解析 Marshal 文件 '#{file_basename}' 时出错: #{e.class}: #{e.message}\n调用栈:\n#{e.backtrace.join("\n")}"
        Logging::Log.error err_msg
        raise "读取或解析 Marshal 文件 '#{file_basename}' 时出错。详情请查看日志。"
      end
    end

    # 从磁盘加载 JSON 文件
    # @param input_file [String] 输入文件路径
    # @return [Object] 解析后的 Ruby 对象 (Hash, Array, etc.)
    # @raise [RuntimeError] 如果发生 JSON 解析错误或其他读写错误
    def self.load_json_data(input_file)
      file_basename = File.basename(input_file)
      Logging::Log.debug "加载 JSON 数据: #{file_basename}" if Logging::Log.debug?
      begin
        json_string = File.read(input_file, encoding: "UTF-8")
        data = Oj.load(json_string, mode: :compat, create_additions: true)
        if data.is_a?(Hash) && File.basename(input_file, ".json") == "MapInfos"
          data["__RM-Toolkit_source_file__"] = input_file
        end
        data
      rescue Oj::ParseError => e
        err_msg = "文件 '#{input_file}' 中 JSON 解析错误 (Oj): #{e.message}"
        Logging::Log.error err_msg
        raise "文件 '#{file_basename}' 中 JSON 解析错误。详情请查看日志。"
      rescue => e
        err_msg = "读取或解析 JSON 文件 '#{input_file}' 时出错: #{e.class}: #{e.message}\n调用栈:\n#{e.backtrace.join("\n")}"
        Logging::Log.error err_msg
        raise "读取或解析 JSON 文件 '#{file_basename}' 时出错。详情请查看日志。"
      end
    end

    # 将 Ruby 数据结构写入 JSON 文件
    # @param output_file [String] 输出文件路径
    # @param data [Object] 要写入的数据
    # @raise [RuntimeError] 如果发生写入错误
    def self.write_json_data(output_file, data)
      file_basename = File.basename(output_file)
      Logging::Log.debug "写入 JSON 数据到: #{file_basename}" if Logging::Log.debug?
      # 确保输出目录存在
      FileUtils.mkdir_p(File.dirname(output_file))
      begin
        # 使用 Oj 生成格式化的 JSON 字符串 (兼容模式, 2空格缩进)
        json_string = Oj.dump(data, mode: :compat, indent: 2)
        # 以 UTF-8 编码写入文件
        File.write(output_file, json_string, encoding: "UTF-8")
      rescue => e
        # 捕获所有可能的写入异常
        err_msg = "写入 JSON 文件 '#{output_file}' 时出错: #{e.class}: #{e.message}\n调用栈:\n#{e.backtrace.join("\n")}"
        Logging::Log.error err_msg
        raise "写入 JSON 文件 '#{file_basename}' 时出错。详情请查看日志。"
      end
    end

    # 将 Ruby 对象序列化并写入 Marshal (RVData/RXData) 文件
    # @param output_file [String] 输出文件路径
    # @param restored_object [Object] 要序列化的对象
    # @raise [TypeError] 如果对象结构不正确，导致 Marshal 失败 (常见于 Table, Color, Tone)
    # @raise [RuntimeError] 如果发生其他写入错误
    def self.write_marshal_data(output_file, restored_object)
      file_basename = File.basename(output_file)
      Logging::Log.debug "写入 Marshal 数据到: #{file_basename}" if Logging::Log.debug?
      # 确保输出目录存在
      FileUtils.mkdir_p(File.dirname(output_file))
      begin
        # 序列化对象
        dumped_data = Marshal.dump(restored_object)
        # 以二进制模式写入文件
        File.binwrite(output_file, dumped_data)
      rescue TypeError => e
        # 捕获常见的序列化 TypeError，并尝试定位问题
        problem_info = find_problematic_path(restored_object) do |obj|
          # 检查 Color/Tone 是否有 nil 属性
          is_bad_color_tone = (obj.is_a?(Tone) || obj.is_a?(Color)) && obj.instance_variables.any? { |ivar| obj.instance_variable_get(ivar).nil? }
          # 检查 Table 结构是否完整且元素类型正确
          is_bad_table = obj.is_a?(Table) && (obj.instance_variable_get(:@elements).nil? ||
                                              !obj.instance_variable_get(:@elements).is_a?(Array) ||
                                              obj.instance_variable_get(:@elements).any? { |el| !el.is_a?(Integer) } ||
                                              obj.instance_variable_get(:@xsize).nil? ||
                                              obj.instance_variable_get(:@ysize).nil? ||
                                              obj.instance_variable_get(:@zsize).nil?)
          # 检查 Animation::Frame 的 cell_data 是否存在 (如果 Frame 类已定义)
          is_bad_anim_frame = defined?(RPG::Animation::Frame) && obj.is_a?(RPG::Animation::Frame) && obj.instance_variable_get(:@cell_data).nil?
          # 检查 Area 的 rect 是否存在 (如果 Area 类已定义)
          is_bad_area = defined?(RPG::Area) && obj.is_a?(RPG::Area) && obj.instance_variable_get(:@rect).nil?

          is_bad_color_tone || is_bad_table || is_bad_anim_frame || is_bad_area
        end
        # 构造错误消息上下文
        context = problem_info ? " 问题可能位于路径 #{problem_info[:path]} 的对象: #{problem_info[:object].class} #{problem_info[:object].inspect[0..200]}..." : ""
        err_msg = "写入 Marshal 文件 '#{output_file}' 时发生 TypeError: #{e.message}。#{context} 请检查对象初始化和恢复逻辑。"
        Logging::Log.error err_msg
        raise TypeError, "写入 Marshal 文件 '#{file_basename}' 时发生 TypeError。详情请查看日志。"
      rescue => e
        # 捕获其他所有可能的写入异常
        err_msg = "写入 Marshal 文件 '#{output_file}' 时发生未知错误: #{e.class}: #{e.message}\n调用栈:\n#{e.backtrace.join("\n")}"
        Logging::Log.error err_msg
        raise "写入 Marshal 文件 '#{file_basename}' 时出错。详情请查看日志。"
      end
    end

    # 递归查找对象图中满足特定条件的第一个对象及其路径 (用于调试)
    # @param object [Object] 起始对象
    # @param current_path [String] 当前路径字符串
    # @param visited [Set] 已访问对象的 object_id 集合，防止无限循环
    # @param block [Proc] 用于检查对象是否满足条件的块
    # @return [Hash, nil] 包含 :path 和 :object 的哈希，如果找到则返回；否则返回 nil
    def self.find_problematic_path(object, current_path = "root", visited = Set.new, &block)
      # 跳过基本类型和无 object_id 的对象
      return nil unless object.respond_to?(:object_id)
      return nil if object.is_a?(Numeric) || object.is_a?(TrueClass) || object.is_a?(FalseClass) || object.is_a?(Symbol) || object.is_a?(String)

      oid = object.object_id
      # 如果已访问过此对象实例，则返回 nil 防止循环
      return nil if visited.include?(oid)
      visited.add(oid)

      result = nil
      begin
        # 检查当前对象是否满足条件
        if block.call(object)
          Logging::Log.debug "在路径 #{current_path} 找到问题对象" if Logging::Log.debug?
          return { path: current_path, object: object }
        end

        # 根据对象类型递归遍历
        case object
        when Array
          # 遍历数组元素
          object.each_with_index do |item, index|
            result = find_problematic_path(item, "#{current_path}[#{index}]", visited, &block)
            break if result # 找到后立即停止遍历
          end
        when Hash
          # 遍历哈希值 (忽略内部使用的键)
          object.reject { |k, _| k == "__RM-Toolkit_source_file__" }.each do |key, value|
            result = find_problematic_path(value, "#{current_path}{#{key.inspect}}", visited, &block)
            break if result # 找到后立即停止遍历
          end
        else
          # 遍历对象的实例变量 (如果支持)
          if object.respond_to?(:instance_variables)
            object.instance_variables.each do |ivar|
              begin
                value = object.instance_variable_get(ivar)
                result = find_problematic_path(value, "#{current_path}.#{ivar}", visited, &block)
                break if result # 找到后立即停止遍历
              rescue StandardError => e
                # 忽略访问实例变量时可能发生的错误 (例如权限问题)
                Logging::Log.debug "在 find_problematic_path 中访问实例变量 #{ivar} 时出错: #{e.message}" if Logging::Log.debug?
              end
            end
          end
        end
      ensure
        # 确保在函数返回前将当前对象移出 visited 集合，允许其他路径访问它
        visited.delete(oid)
      end
      result
    end
  end # module IO

  # --- JSON 导出器 类 ---
  # 负责将加载的 Ruby 对象转换为适合 JSON 导出的格式

module Scripts
    METADATA_FILENAME = "Scripts_info.json".freeze
    SCRIPTS_SUBDIR = "Scripts".freeze
    ASSUMED_NAME_ENCODING = "UTF-8".freeze

    # 解包 Scripts.rvdata
    # @param scripts_array [Array] 从 Scripts.rvdata 加载的数组
    # @param scripts_output_directory [String] 脚本文件和元数据输出的目录 (例如 /path/to/Source/Scripts)
    # @raise [ArgumentError] 如果输入数据不是数组
    def self.unpack(scripts_array, scripts_output_directory)
      # 验证输入类型
      unless scripts_array.is_a?(Array)
        err_msg = "无效的脚本数据: 顶层对象不是数组。"
        Logging::Log.error err_msg
        raise ArgumentError, err_msg
      end

      scripts_output_dir = scripts_output_directory

      Logging::Log.info "确保脚本输出目录存在: #{scripts_output_dir}"
      FileUtils.mkdir_p(scripts_output_dir)

      metadata = [] # 存储脚本元数据
      # 遍历脚本数组
      scripts_array.each_with_index do |script_entry, index|
        # 验证脚本条目格式 [id, name, compressed_code]
        unless script_entry.is_a?(Array) && script_entry.length >= 3
          Logging::Log.warn "跳过索引 #{index} 处无效的脚本条目 (非数组或长度不足): #{script_entry.inspect[0..100]}..."
          next
        end
        id, name_bytes, compressed_code = script_entry[0], script_entry[1], script_entry[2]

        # 验证 ID 类型
        unless id.is_a?(Integer) || (id.respond_to?(:to_i))
          Logging::Log.warn "跳过索引 #{index} 处无效的脚本条目 (ID 非整数): ID=#{id.inspect}"
          next
        end
        id = id.to_i

        # 验证名称类型
        unless name_bytes.is_a?(String)
          Logging::Log.warn "跳过索引 #{index} 处无效的脚本条目 (名称非字符串): Name=#{name_bytes.inspect}"
          next
        end

        # --- 处理脚本名称编码 (用于 JSON 元数据) ---
        name_processed_for_json = "[转换错误]"
        begin
          name_processed_for_json = name_bytes.dup.force_encoding(ASSUMED_NAME_ENCODING).encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          if name_processed_for_json.empty? && !name_bytes.empty?
            name_processed_for_json = "[替换后为空]"
          end
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
          Logging::Log.warn "无法将脚本名称字节处理为 #{ASSUMED_NAME_ENCODING} (ID: #{id}, Index: #{index})。存储占位符。错误: #{e.message}"
          name_processed_for_json = "[编码错误: #{e.message}]"
        rescue => e
          Logging::Log.warn "处理脚本名称时出错 (ID: #{id}, Index: #{index})。存储占位符。错误: #{e.class} - #{e.message}"
          name_processed_for_json = "[处理错误: #{e.message}]"
        end
        # --- 编码处理结束 ---

        # --- 解压缩脚本代码 ---
        script_code = ""
        begin
          if compressed_code.nil? || !compressed_code.is_a?(String) || compressed_code.empty?
            Logging::Log.debug "脚本代码为空或类型无效 (Index #{index}, ID #{id})" if Logging::Log.debug?
            if compressed_code && !compressed_code.is_a?(String)
              Logging::Log.warn "脚本代码类型不正确 (Index #{index}, ID #{id}, Type #{compressed_code.class})。将写入空文件。"
            end
          else
            script_code = Zlib::Inflate.inflate(compressed_code)
          end
        rescue Zlib::Error => e
          Logging::Log.warn "解压缩脚本代码失败 (Index #{index}, ID #{id}, Name '#{name_processed_for_json}'): #{e.class}: #{e.message}。将写入空文件。"
          script_code = ""
        rescue TypeError => e
          Logging::Log.warn "脚本代码不是有效的压缩字符串 (Index #{index}, ID #{id}, Name '#{name_processed_for_json}'): #{e.class}: #{e.message}。将写入空文件。"
          script_code = ""
        end
        # --- 解压缩结束 ---

        # 生成脚本文件名 (按索引顺序)
        script_filename = format("%03d.rb", index)
        script_filepath = File.join(scripts_output_dir, script_filename)

        # 写入脚本文件
        begin
          File.binwrite(script_filepath, script_code)
          Logging::Log.info "  解包脚本: #{script_filename} (ID: #{id}, Name: '#{name_processed_for_json}') 到 #{scripts_output_dir}"
        rescue => e
          Logging::Log.error "写入脚本文件 '#{script_filepath}' 失败: #{e.message}"
        end

        # 添加元数据
        metadata << { id: id, name: name_processed_for_json, index: index }
      end # scripts_array.each end

      metadata_filepath = File.join(scripts_output_dir, METADATA_FILENAME)
      begin
        json_string = Oj.dump(metadata, mode: :compat, indent: 2)
        File.write(metadata_filepath, json_string, encoding: "UTF-8")
        Logging::Log.info "  写入脚本元数据: #{metadata_filepath}"
      rescue => e
        Logging::Log.error "写入脚本元数据文件 '#{metadata_filepath}' 失败: #{e.message}"
      end
    end

    # 打包脚本文件为 Scripts.rvdata
    # @param scripts_input_dir [String] 包含脚本文件和元数据文件的目录 (例如 /path/to/Source/Scripts)
    # @return [Array] 用于 Marshal.dump 的脚本数组
    # @raise [IOError] 如果元数据文件未找到
    # @raise [TypeError] 如果元数据文件内容不是数组
    # @raise [RuntimeError] 如果发生 JSON 解析或其他加载错误
    def self.pack(scripts_input_dir)
      metadata_filepath = File.join(scripts_input_dir, METADATA_FILENAME)
      unless File.exist?(metadata_filepath)
        err_msg = "脚本元数据文件未找到: #{metadata_filepath}"
        Logging::Log.error err_msg
        raise IOError, err_msg
      end

      Logging::Log.info "加载脚本元数据: #{metadata_filepath}"
      metadata = nil
      begin
        json_string = File.read(metadata_filepath, encoding: "UTF-8")
        metadata = Oj.load(json_string, mode: :compat, symbol_keys: false)
      rescue Oj::ParseError => e
        err_msg = "解析脚本元数据 JSON 文件 '#{metadata_filepath}' 失败: #{e.message}"
        Logging::Log.error err_msg
        raise "元数据 JSON 解析错误。详情请查看日志。"
      rescue => e
        err_msg = "加载脚本元数据文件 '#{metadata_filepath}' 失败: #{e.message}"
        Logging::Log.error err_msg
        raise "加载元数据时出错。详情请查看日志。"
      end

      unless metadata.is_a?(Array)
        err_msg = "脚本元数据文件 '#{metadata_filepath}' 的内容不是有效的 JSON 数组。"
        Logging::Log.error err_msg
        raise TypeError, err_msg
      end

      max_index = metadata.map { |info| info["index"] }.compact.max || -1
      scripts_array = Array.new(max_index + 1)

      Logging::Log.info "开始脚本打包过程 (源: #{scripts_input_dir})..."
      metadata.each do |script_info|
        index = script_info["index"]
        id = script_info["id"]
        name = script_info["name"]

        unless index.is_a?(Integer) && index >= 0 && id.is_a?(Integer) && name.is_a?(String)
          Logging::Log.warn "跳过无效的元数据条目: #{script_info.inspect}"
          next
        end

        script_filename = format("%03d.rb", index)
        script_filepath = File.join(scripts_input_dir, script_filename)
        script_code = ""

        if File.exist?(script_filepath)
          begin
            script_code = File.binread(script_filepath)
            Logging::Log.info "  打包脚本: #{script_filename} (ID: #{id}, Name: '#{name}')"
          rescue => e
            Logging::Log.warn "读取脚本文件 '#{script_filepath}' 失败: #{e.message}。将使用空代码。"
            script_code = ""
          end
        else
          Logging::Log.warn "脚本文件未找到: '#{script_filepath}' (基于元数据)。将使用空代码。"
          script_code = ""
        end

        compressed_code = Zlib::Deflate.deflate("")
        begin
          compressed_code = Zlib::Deflate.deflate(script_code)
        rescue => e
          Logging::Log.error "压缩脚本代码失败 (Index #{index}, ID #{id}, Name '#{name}'): #{e.message}。将使用压缩后的空字符串。"
        end

        scripts_array[index] = [id, name, compressed_code]
      end

      Logging::Log.info "脚本打包完成，准备进行 Marshal 转储。"
      return scripts_array
    end

    def self.remove_scripts(scripts_input_dir, remove_index: nil, prune_empty: false)
      metadata_filepath = File.join(scripts_input_dir, METADATA_FILENAME)
      raise IOError, "元数据文件未找到: #{metadata_filepath}" unless File.exist?(metadata_filepath)

      json_string = File.read(metadata_filepath, encoding: "UTF-8")
      metadata = Oj.load(json_string, mode: :compat, symbol_keys: false)
      raise TypeError, "元数据不是数组" unless metadata.is_a?(Array)

      doomed = []
      if remove_index
        entry = metadata.find { |m| m["index"] == remove_index }
        raise "未找到 index=#{remove_index} 的脚本" unless entry
        doomed << entry
      end

      if prune_empty
        metadata.each do |m|
          f = File.join(scripts_input_dir, format("%03d.rb", m["index"]))
          doomed << m if File.exist?(f) && File.size(f) == 0
        end
      end

      return if doomed.empty?

      del_is = doomed.map { |m| m["index"] }.sort.uniq
      Logging::Log.info "删除脚本索引: #{del_is.join(', ')}"
      metadata.reject! { |m| del_is.include?(m["index"]) }

      old_to_new = {}
      metadata.sort_by { |m| m["index"] }.each_with_index do |m, i|
        old_to_new[m["index"]] = i
        m["index"] = i
      end

      del_is.each { |i| FileUtils.rm_f(File.join(scripts_input_dir, format("%03d.rb", i))) }

      old_to_new.select { |old_i, new_i| old_i != new_i }.sort.reverse.each do |old_i, new_i|
        old_f = File.join(scripts_input_dir, format("%03d.rb", old_i))
        new_f = File.join(scripts_input_dir, format("%03d.rb", new_i))
        FileUtils.mv(old_f, new_f) if File.exist?(old_f)
      end

      File.write(metadata_filepath, Oj.dump(metadata, mode: :compat, indent: 2))
      Logging::Log.info "元数据已更新，剩余 #{metadata.size} 个脚本"
    end
  end # module Scripts
end # module Converter
