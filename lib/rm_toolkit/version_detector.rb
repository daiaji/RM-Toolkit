# lib/version_detector.rb
require 'json'
require 'pathname'
require 'inifile'
require_relative 'utils'
require_relative 'logging'

module VersionDetector
  # 启发式评分模型的证据清单
  INDICATORS = {
    # 黄金标准证据 (Golden Evidence)
    library_rgss1:      { check: ->(dir) { game_ini_key_matches(dir, "Library", /RGSS1\d{2,}/i) }, score: 100, version: "RGSS1" },
    library_rgss2:      { check: ->(dir) { game_ini_key_matches(dir, "Library", /RGSS2\d{2,}/i) }, score: 100, version: "RGSS2" },
    library_rgss3:      { check: ->(dir) { game_ini_key_matches(dir, "Library", /RGSS3\d{2,}/i) }, score: 100, version: "RGSS3" },
    rpgmaker_name_mv:   { check: ->(dir) { check_js_file_content(dir, /RPGMAKER_NAME\s*=\s*['"](MV|RPG Maker MV)['"]/i) }, score: 100, version: "MV" },
    rpgmaker_name_mz:   { check: ->(dir) { check_js_file_content(dir, /RPGMAKER_NAME\s*=\s*['"](MZ|RPG Maker MZ)['"]/i) }, score: 100, version: "MZ" },
    
    # 强力证据 (Strong Evidence)
    scripts_rxdata:     { check: ->(dir) { game_ini_key_matches(dir, "Scripts", /\.rxdata$/i) }, score: 75, version: "RGSS1" },
    scripts_rvdata:     { check: ->(dir) { game_ini_key_matches(dir, "Scripts", /\.rvdata$/i) }, score: 75, version: "RGSS2" },
    scripts_rvdata2:    { check: ->(dir) { game_ini_key_matches(dir, "Scripts", /\.rvdata2$/i) }, score: 75, version: "RGSS3" },
    www_directory:      { check: ->(dir) { Dir.exist?(File.join(dir, "www")) }, score: 60, version: "MV" },
    
    # 可靠证据 (Reliable Evidence)
    project_mz:         { check: ->(dir) { File.exist?(File.join(dir, 'game.rmmzproject')) }, score: 50, version: "MZ" },
    project_rgss3:      { check: ->(dir) { File.exist?(File.join(dir, 'Game.rvproj2')) }, score: 50, version: "RGSS3" },
    project_rgss2:      { check: ->(dir) { File.exist?(File.join(dir, 'Game.rvproj')) }, score: 50, version: "RGSS2" },
    project_rgss1:      { check: ->(dir) { File.exist?(File.join(dir, 'Game.rxproj')) }, score: 50, version: "RGSS1" },
    macos_frameworks:   { check: ->(dir) { macos_bundle_exists?(dir, with_frameworks: true) }, score: 50, version: "MZ" },
    
    # 辅助证据 (Supporting Evidence)
    encrypted_mz:       { check: ->(dir) { !Dir.glob(File.join(find_data_directory(dir, "MZ"), "{data,img,audio}", "**", "*.{png_,ogg_,m4a_}")).empty? }, score: 20, version: "MZ" },
    encrypted_mv:       { check: ->(dir) { !Dir.glob(File.join(find_data_directory(dir, "MV"), "{data,img,audio}", "**", "*.rpgmv{p,o,m}")).empty? }, score: 20, version: "MV" },
    
    # 负面证据 (Contradictory Evidence)
    www_contradicts_mz: { check: ->(dir) { Dir.exist?(File.join(dir, "www")) }, score: -50, version: "MZ" }
  }.freeze

  class << self
    def detect(base_dir)
      scores = Hash.new(0)
      INDICATORS.each do |key, indicator|
        begin
          if indicator[:check].call(base_dir)
            scores[indicator[:version]] += indicator[:score]
            Logging::Log.debug "证据命中: #{key} -> #{indicator[:version]} 分数变化 #{indicator[:score] > 0 ? '+' : ''}#{indicator[:score]}"
          end
        rescue => e
          Logging::Log.warn "检测证据 #{key} 时出错: #{e.message}"
        end
      end
      
      Logging::Log.info "版本检测评分结果: #{scores.inspect}"
      return nil if scores.empty? || scores.values.all?(&:zero?)
      
      top_version, top_score = scores.max_by { |_, score| score }
      
      return nil if top_score < 40 # 如果最高分低于阈值，则认为不确定
      
      top_version
    end

    private
    
    def game_ini_key_matches(dir, key, pattern)
      ini_path = File.join(dir, "Game.ini")
      return false unless File.exist?(ini_path)
      
      @ini_files ||= {}
      @ini_files[dir] ||= begin
        content = File.binread(ini_path)
        encoding = Utils.send(:detect_encoding_safe, content) || 'UTF-8'
        IniFile.new(content: content, encoding: encoding)
      rescue; nil; end
      
      return false unless @ini_files[dir] && @ini_files[dir].has_section?("Game")
      value = @ini_files[dir]["Game"][key]
      value && value.match?(pattern)
    end
    
    def check_js_file_content(dir, pattern)
      data_dir = find_data_directory(dir, "MZ") # Assume MZ structure for core files
      return false unless data_dir
      path_to_check = File.join(data_dir, 'js', 'rpg_core.js')
      return false unless File.exist?(path_to_check)
      
      content_sample = File.read(path_to_check, 8192) rescue ""
      content_sample.match?(pattern)
    end
    
    def macos_bundle_exists?(dir, with_frameworks: false)
      mac_app_dir = Dir.glob(File.join(dir, "*.app")).first
      return false unless mac_app_dir
      return true unless with_frameworks

      frameworks_dir = File.join(mac_app_dir, "Contents", "Frameworks")
      Dir.exist?(frameworks_dir)
    end
    
    def find_data_directory(dir, version)
      mac_app_dir = Dir.glob(File.join(dir, "*.app")).first
      if mac_app_dir
        potential_path = File.join(mac_app_dir, "Contents", "Resources", "app.nw")
        return potential_path if Dir.exist?(potential_path)
      end
      if version == "MV"
        www_dir = File.join(dir, "www")
        return www_dir if Dir.exist?(www_dir)
      end
      dir
    end
  end
end