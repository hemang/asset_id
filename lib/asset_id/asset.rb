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
    @@skip_assets = false
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
      
      @@skip_assets = options[:skip_assets] if options[:skip_assets]
      @@skip_assets ||= []
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
        asset.replace_js_images!(:prefix => @@asset_host) if asset.js? && @replace_images
        
        asset.fingerprint
        if options[:debug]
          puts "Relative path: #{asset.relative_path}" 
          puts "Fingerprint: #{asset.fingerprint}"
        end
        
        #If content modified, replace content of original
        asset.write_data if @@replace_images && (asset.css? || asset.js?)
                  
        File.rename(Asset.path_prefix + relative_path, Asset.path_prefix + asset.fingerprint) if @@rename

        #copy, if specified and not renaming
        if !@@rename && @@copy
          copy_path = File.join(Asset.path_prefix, asset.fingerprint)
          FileUtils.cp(asset.path, copy_path) if !File.exists? copy_path
        end  
      end
      Cache.save!
    end
    
    def write_data
      output_dir = File.dirname relative_path
      FileUtils.mkdir_p(output_dir) unless File.exists?(output_dir)
      raise OutputNotWritable, "AssetId doesn't have permission to write to \"#{output_dir}\"" unless File.writable?(output_dir)
      File.open(absolute_path, 'wb+') {|f| f.write(data) }
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
      #more detailed solution - https://github.com/where/asset_id/commit/b925b014df16f478570ca75b5347c437652d68fe
      @path = path.split('?')[0]
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
      @@skip_assets.each do |skip_regex|
        return p if relative_path =~ skip_regex 
      end
      
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
    
    def js?
      mime_type = 'application/javascript'
    end
    
    def replace_css_images!(options={})
      options.merge :regexp => Regexp.new(/url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi)
      options.merge :replace_with_b4_uri => "url("
      options.merge :replace_with_after_uri => ")"
      replace_images!(options)
    end
    
    def replace_js_images!(options={})
      options.merge :regexp => Regexp.new(/src=(?:"([^"]*)"|'([^']*)'|([^)]*))/mi)
      options.merge :replace_with_b4_uri => "src=\""
      options.merge :replace_with_after_uri => "\""
      replace_images!(options)
    end
    
    def replace_images!(options={})
      options[:prefix] ||= ''
      #defaults to css regex
      regexp = options[:regexp] || /url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi 
      data.gsub! regexp do |match|
        begin
          # $1 is the double quoted string, $2 is single quoted, $3 is no quotes
          uri = ($1 || $2 || $3).to_s.strip
          uri.gsub!(/^\.\.\//, '/')
          
          b4_uri = options[:replace_with_b4_uri] || "url("
          after_uri = options[:replace_with_b4_uri] || ")"
          
          original = "#{b4_uri}#{uri}#{after_uri}"
        
          # if the uri appears to begin with a protocol then the asset isn't on the local filesystem
          # uri is unchanged for data and font uris
          if uri =~ /[a-z]+:\/\//i || uri =~ /data:/i || uri =~ /^data:font/
            original
          else
            asset = Asset.new(uri)
          
            puts "  - Changing CSS URI #{uri} to #{options[:prefix]}#{asset.fingerprint}" if @@debug
          
            # TODO: Check the referenced asset is in the asset_paths
            # Suggested solution below. But, rescue is probably a better solution in case of nested paths and such
            # - https://github.com/KeasInc/asset_id/commit/0fbd108c06ad18f50bfa63073b2a8c5bbac154fb
            # - https://github.com/KeasInc/asset_id/commit/14ce9124938c15734ec0c61496fd371de2b8087c
            "#{b4_uri}#{options[:prefix]}#{asset.fingerprint}#{after_uri}"
          end
        rescue Errno::ENOENT => e
          puts "  - Warning: #{uri} not found" if @@debug
          original #TODO: Should this have asset_host?
        end
    end 
    
    end
    
    def gzip!
      # adapted from https://github.com/blakink/asset_id
      @data = returning StringIO.open('', 'w') do |gz_data|
        gz = Zlib::GzipWriter.new(gz_data, Zlib::BEST_COMPRESSION, nil)
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