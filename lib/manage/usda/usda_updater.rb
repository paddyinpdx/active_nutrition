require 'open-uri'
require 'fileutils'
require 'zip/zip'
require 'yaml'

module ActiveNutrition
  class USDAUpdater
    BASE_URL = "http://www.ars.usda.gov/"
    BASE_PATH = "SP2UserFiles/Place/12354500/Data/SR{{release}}/dnload/"
    FULL_FILE = "sr{{release}}.zip"
    UPDATE_FILE = "sr{{release}}upd.zip"
    CURRENT_RELEASE = 24  # as of 2011-11-6
    DATA_DIR = File.join(File.dirname(File.dirname(File.dirname(__FILE__))), "data")
    IMPORT_CHUNK_SIZE = 1000

    def initialize(options = {})
      @release = (options[:release] || CURRENT_RELEASE).to_s
      @usda_map = YAML::load_file(File.join(File.dirname(File.dirname(__FILE__)), "usda_map.yml"))
      @type = options[:type] || :update
      @path, @file = self.url_for(@type)
      @zip_file = File.join(DATA_DIR, @file)
      @zip_dir = @zip_file.chomp(File.extname(@zip_file))
    end

    def update
      @usda_map.each_pair do |model_const, data|
        if ActiveNutrition.const_defined?(model_const.to_sym)
          model = ActiveNutrition.const_get(model_const.to_sym)
          cur_file = File.join(@zip_dir, data["file_name"])
          parser = USDAParser.new(cur_file)
          record_total = `wc -l "#{cur_file}"`.to_i
          new_records = []
          record_count = 0

          parser.each do |values|
            new_record = model.new

            data["attribute_order"].each_with_index do |field, index|
              # update each attribute by explicitly calling the attr= method, just in case
              # there are custom methods in the model class
              new_record.send("#{field}=".to_sym, values[index])
            end

            new_records << new_record
            record_count += 1

            if new_records.size == IMPORT_CHUNK_SIZE
              model.import(new_records)
              new_records.clear
              yield [model.to_s, record_count, record_total] if block_given?
            end
          end

          # import stragglers
          model.import(new_records)
        end
      end
    end

    def reset_db
      @usda_map.each_key do |model_const|
        if ActiveNutrition.const_defined?(model_const.to_sym)
          model = ActiveNutrition.const_get(model_const.to_sym)
          model.destroy_all
        end
      end
    end

    def clean
      File.unlink(@zip_file) if File.exist?(@zip_file)
      FileUtils.rm_rf(@zip_dir) if File.exist?(@zip_dir)
    end

    def download
      File.open(File.join(DATA_DIR, @file), "wb") do |f|
        f.sync = true
        f.write(open("#{BASE_URL}#{@path}#{@file}").read)
      end
    end

    def unzip
      Zip::ZipFile.open(@zip_file) do |zip_file|
        zip_file.each do |f|
          next unless f.file?
          f_path = File.join(@zip_dir, f.name)
          FileUtils.mkdir_p(File.dirname(f_path))
          zip_file.extract(f, f_path) unless File.exist?(f_path)
        end
      end
    end

    protected

    def url_for(type = :full)
      file = case type
        when :full then FULL_FILE
        when :update then UPDATE_FILE
        else UPDATE_FILE
      end

      [BASE_PATH.gsub("{{release}}", @release), file.gsub("{{release}}", @release)]
    end
  end
end