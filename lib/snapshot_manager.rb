# lib/snapshot_manager.rb
# 负责处理源码目录的快照创建、列出和恢复。

require 'fileutils'
require 'pathname'
require_relative 'logging'

class SnapshotManager
  def initialize(base_dir, config)
    @base_dir = Pathname.new(base_dir)
    @config = config
    
    @structure_config = @config['project_structure']
    @snapshot_config = @config['snapshot_options']

    @source_dir_name = @structure_config['source_data_dir']
    @source_dir_path = @base_dir.join(@source_dir_name)
    
    @snapshots_root_name = @snapshot_config['directory']
    @snapshots_root_path = @base_dir.join(@snapshots_root_name)
  end

  # 创建快照，增加 auto_name 用于自动快照场景
  def create(user_name = nil, auto_name: "auto")
    Logging::Log.info "开始创建源码目录 '#{@source_dir_name}' 的快照..."

    unless @source_dir_path.directory?
      raise "错误: 源码目录 '#{@source_dir_path}' 不存在，无法创建快照。"
    end

    FileUtils.mkdir_p(@snapshots_root_path)
    
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    # 如果用户提供了名称，则使用用户名称；否则使用自动名称
    base_name = user_name || auto_name
    cleaned_name = base_name ? base_name.gsub(/[\s\W]+/, '_').gsub(/_+/, '_').chomp('_') : ""
    
    format_string = @snapshot_config['format']
    snapshot_dir_name_base = format_string
                             .gsub('{dirname}', @source_dir_name)
                             .gsub('{name}', cleaned_name)
                             .gsub('{timestamp}', timestamp)
                             .gsub(/__+/, '_').chomp('_')

    snapshot_path = @snapshots_root_path.join(snapshot_dir_name_base)
    
    # --- 修改：处理名称冲突 ---
    # 如果目标路径已存在，则在后面添加一个序号
    counter = 1
    while snapshot_path.exist?
      new_name = "#{snapshot_dir_name_base}_#{counter}"
      snapshot_path = @snapshots_root_path.join(new_name)
      counter += 1
      Logging::Log.warn "快照目录已存在，尝试新名称: #{snapshot_path.basename}" if counter > 1
    end
    # --- 修改结束 ---

    begin
      FileUtils.cp_r(@source_dir_path.to_s, snapshot_path.to_s, preserve: true)
      Logging::Log.info "成功创建快照: #{snapshot_path.relative_path_from(@base_dir)}"
    rescue => e
      FileUtils.rm_rf(snapshot_path) if snapshot_path.exist?
      raise "创建快照失败: #{e.message}"
    end
  end

  # 列出快照 (不变)
  def list
    puts "可用的源码快照 (位于 '#{@snapshots_root_name}'):"
    
    unless @snapshots_root_path.directory?
      puts "  (没有找到快照目录)"
      return
    end

    snapshots = Dir.children(@snapshots_root_path).select do |entry|
      @snapshots_root_path.join(entry).directory?
    end.sort

    if snapshots.empty?
      puts "  (没有找到任何快照)"
    else
      snapshots.each do |snapshot_name|
        puts "  - #{snapshot_name}"
      end
    end
  end

  # 恢复快照 (不变)
  def restore(snapshot_name, force = false)
    raise "错误: 必须提供要恢复的快照名称。" if snapshot_name.nil? || snapshot_name.empty?

    snapshot_path = @snapshots_root_path.join(snapshot_name)
    unless snapshot_path.directory?
      raise "错误: 找不到名为 '#{snapshot_name}' 的快照。"
    end

    Logging::Log.info "准备从快照 '#{snapshot_name}' 恢复到 '#{@source_dir_name}'..."

    unless force
      puts "============================== 警告 =============================="
      puts "此操作将永久删除当前的 '#{@source_dir_name}' 目录,"
      puts "并用快照 '#{snapshot_name}' 的内容替换它。"
      puts "此操作无法撤销！"
      puts "=================================================================="
      print "请输入 'yes' 以确认恢复: "
      
      confirmation = $stdin.gets.chomp.downcase
      
      unless confirmation == 'yes'
        puts "操作已取消。"
        return
      end
    end

    Logging::Log.warn "正在恢复快照！将删除当前源码目录..."
    begin
      FileUtils.rm_rf(@source_dir_path) if @source_dir_path.exist?
      FileUtils.cp_r(snapshot_path.to_s, @source_dir_path.to_s, preserve: true)
      Logging::Log.info "成功从快照 '#{snapshot_name}' 恢复到 '#{@source_dir_name}'。"
      puts "恢复成功。"
    rescue => e
      raise "恢复快照时发生错误: #{e.message}"
    end
  end
end