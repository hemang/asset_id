require 'yaml'

module AssetID
  class Cache
    
    def self.empty
      @cache = {}
    end
    
    def self.cache
      @cache ||= (YAML.load_file(cache_path) rescue {})
    end
    
    def self.cache_file_name
    
    end
    
    def self.cache_path
      filename = 'asset_id_cache_' + ENV['RACK_ENV'] + '.yml'
      File.join(Rails.root, 'config', filename)
    end
    
    def self.get(asset)
      cache[asset.relative_path]
    end
    
    def self.hit?(asset)
      return true if cache[asset.relative_path] and cache[asset.relative_path][:fingerprint] == asset.fingerprint
      cache[asset.relative_path] = {:fingerprint => asset.fingerprint}
      false
    end
  
    def self.miss?(asset)
      !hit?(asset)
    end
    
    def self.save!
      puts "Begin writing file to #{cache_path}"
      File.open(cache_path, 'w') {|f| f.write(YAML.dump(cache))}
      puts "Finished writing file to #{cache_path}"
    end
  
  end
end