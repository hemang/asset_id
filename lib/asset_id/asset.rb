require 'digest/md5'
require 'mime/types'
require 'time'
require 'zlib'

module AssetID
  class Asset
    
    DEFAULT_ASSET_PATHS = ['favicon.ico', 'images', 'javascripts', 'stylesheets']
    @@asset_paths = DEFAULT_ASSET_PATHS
    
    DEFAULT_GZIP_TYPES = ['text/css', 'application/javascript']
    @@gzip_types = DEFAULT_GZIP_TYPES
    
    @@debug = false
    @@nocache = false
    @@nofingerprint = false
    @@assetsfingerprint = false
    @@rename = false
    @@replace_images = false
    @@copy = false
    @@gzip = false
    @@asset_host = false
    
    def self.init(options)
      @@debug = options[:debug] if options[:debug]
      @@nocache = options[:nocache] if options[:nocache]
      
      @@nofingerprint = options[:nofingerprint] if options[:nofingerprint]
      @@nofingerprint ||= []
      
      @@assetsfingerprint = options[:assetsfingerprint] if options[:assetsfingerprint]
      @@rename = options[:rename] if options[:rename]  
      @@copy = options[:copy] if options[:copy]  
      @@replace_images = options[:replace_images] if options[:replace_images]  
      @@gzip = options[:gzip] if options[:gzip] 
      
      @@asset_host = options[:asset_host] if options[:asset_host]
      @@asset_host ||= ''
    end

    def self.process!(options={})
      init(options)
      assets.each do |asset|
        #replace css images is intentionally before fingerprint       
        asset.replace_css_images!(:prefix => @@asset_host) if asset.css? && @@replace_images
        
        
        if asset.gzip_type? && @@gzip
          asset.gzip!
        end
        
        asset.fingerprint
        if options[:debug]
          puts "Relative path: #{asset.relative_path}" 
          puts "Fingerprint: #{asset.fingerprint}"
        end
      
        File.rename(Asset.path_prefix + p, Asset.path_prefix + fingerprint_name) if @@rename
        FileUtils.cp(asset.path, File.join(Asset.path_prefix, asset.fingerprint)) if @@copy
      end
      Cache.save!
    end
    
    def self.asset_paths
      @@asset_paths
    end

    def self.gzip_types
      @@gzip_types
    end
    
    def self.asset_paths=(paths)
      @@asset_paths = paths
    end
    
    def self.gzip_types=(types)
      @@gzip_types = types
    end

    def self.assets(paths=Asset.asset_paths)
      paths.inject([]) {|assets, path|
        path = Asset.get_absolute_path(path)
        a = Asset.new(path)
        assets << a if a.is_file? and !a.cache_hit?
        
        assets += Dir.glob(path+'/**/*').inject([]) {|m, file|
          a = Asset.new(file); m << a if a.is_file? and !a.cache_hit?; m 
          }
        }
    end
    
    def self.fingerprint(path)
      asset = Asset.new(path)
      hit = Cache.get(asset)
      return hit[:fingerprint] if hit
      return asset.fingerprint
    end
    
    attr_reader :path
    
    def initialize(path)
      @path = path
      @path = absolute_path
    end
    
    def self.path_prefix
      File.join Rails.root, 'public'
    end
    
    def absolute_path
      Asset.get_absolute_path(path)
    end
    
    def self.get_absolute_path(for_path)
      for_path =~ /#{Asset.path_prefix}/ ? for_path : File.join(Asset.path_prefix, for_path)
    end
    
    def relative_path
      path.gsub(Asset.path_prefix, '')
    end
    
    def gzip_type?
      Asset.gzip_types.include? mime_type
    end
    
    def data
      @data ||= File.read(path)
    end
    
    def md5
      @digest ||= Digest::MD5.hexdigest(data)
    end
    
    def fingerprint
      p = relative_path
      return p if relative_path =~ /^\/assets\// && !@@assetsfingerprint 
      
      #Handle .gz files - eg. application.css.gz -> application-12345534123.css.gz 
      extension = (p =~ /\.gz$/ ? File.extname(File.basename(p, ".gz")) + ".gz" : File.extname(p))     
      File.join File.dirname(p), "#{File.basename(p, extension)}-#{md5}#{extension}"  
    end
    
    def mime_type
      MIME::Types.of(path).first.to_s
    end
    
    def css?
      mime_type == 'text/css'
    end
    
    def replace_css_images!(options={})
      options[:prefix] ||= ''
      # adapted from https://github.com/blakink/asset_id
      data.gsub! /url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi do |match|
        begin
          # $1 is the double quoted string, $2 is single quoted, $3 is no quotes
          uri = ($1 || $2 || $3).to_s.strip
          uri.gsub!(/^\.\.\//, '/')
          
          # if the uri appears to begin with a protocol then the asset isn't on the local filesystem
          # uri is unchanged for data and font uris
          if uri =~ /[a-z]+:\/\//i || uri =~ /data:/i || uri =~ /^data:font/
            "url(#{uri})"
          else
            asset = Asset.new(uri)
            
            puts "  - Changing CSS URI #{uri} to #{options[:prefix]}#{asset.fingerprint}" if @@debug
            
            # TODO: Check the referenced asset is in the asset_paths
            # Suggested solution below. But, rescue is probably a better solution in case of nested paths and such
            # - https://github.com/KeasInc/asset_id/commit/0fbd108c06ad18f50bfa63073b2a8c5bbac154fb
            # - https://github.com/KeasInc/asset_id/commit/14ce9124938c15734ec0c61496fd371de2b8087c
            "url(#{options[:prefix]}#{asset.fingerprint})"
          end
        rescue Errno::ENOENT => e
          puts "  - Warning: #{uri} not found" if @@debug
          "url(#{uri})"
        end
      end
    end
    
    def gzip!
      #TODO: copy instead of replace original
      
      # adapted from https://github.com/blakink/asset_id
      @data = returning StringIO.open('', 'w') do |gz_data|
        gz = Zlib::GzipWriter.new(gz_data, nil, nil)
        gz.write(data)
        gz.close
      end.string
    end
    
    def expiry_date
      @expiry_date ||= (Time.now + (60*60*24*365)).httpdate
    end
    
    def cache_headers
      {'Expires' => expiry_date, 'Cache-Control' => 'public'} # 1 year expiry
    end
    
    def gzip_headers
      {'Content-Encoding' => 'gzip', 'Vary' => 'Accept-Encoding'}
    end
    
    def is_file?
      File.exists? absolute_path and !File.directory? absolute_path
    end
    
    def cache_hit?
      return false if @@nocache or Cache.miss? self
      puts "AssetID: #{relative_path} - Cache Hit" if @@debug
      return true 
    end
    
  end
end