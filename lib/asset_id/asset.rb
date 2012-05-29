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
    @@skip_assets = nil
    @@rename = false
    @@replace_images = false
    @@copy = false
    @@gzip = false
    @@asset_host = false
    @@web_host = false
    @@remove_timestamps = true
    @@replace_font_gz = false
    @@gz_suffix = '.gzip'
    
    attr_reader :path
    
    def self.init(options)
      @@debug = options[:debug] || false
      @@nocache = options[:nocache] || false
      @@nofingerprint = options[:nofingerprint] || []      
      @@skip_assets = options[:skip_assets] || nil
      @@rename = options[:rename] || false
      @@copy = options[:copy] || false
      @@replace_images = options[:replace_images] || false
      @@gzip = options[:gzip] || false     
      @@remove_timestamps = !(options[:remove_timestamps] == false)
      @@asset_host = options[:asset_host] || ''       
      @@web_host = options[:web_host] || ''
      @@replace_font_gz = options[:replace_font_gz] || false
      @@gz_suffix = options[:gz_suffix] || '.gzip'
    end
    
    def initialize(path)
      @path = path
      
      #more detailed solution - https://github.com/where/asset_id/commit/b925b014df16f478570ca75b5347c437652d68fe
      pos = [path.index("#"), path.index("?")].compact.min
      @path = path.slice(0,pos) unless pos.nil?
      
      @path = absolute_path
    end

    def self.process!(options={})
      init(options)
      assets.each do |asset|
        #replace css images is intentionally before fingerprint of current asset       
        asset.replace_css_images!(:asset_host => @@asset_host, :web_host => @@web_host) if asset.css? && @@replace_images
        asset.replace_js_images!(:asset_host => @@asset_host, :web_host => @@web_host) if asset.js? && @@replace_images
        
        #If content modified, replace content of original
        #Fingerprinting for current asset should be after content replace
        asset.write_data if @@replace_images && (asset.css? || asset.js?)
        
        if options[:debug]
          puts "Relative path: #{asset.relative_path}" 
          puts "Fingerprint: #{asset.fingerprint}"
        end
        
        files = []
        fingerprint_path = File.join(Asset.path_prefix, asset.fingerprint)
        files << fingerprint_path
        
        if @@rename 
          puts "Renaming #{asset.path} to #{fingerprint_path}" if options[:debug]         
          File.rename(asset.path, fingerprint_path) 
        end

        #copy, if specified and not renaming
        if !@@rename && @@copy
          puts "Copying #{asset.path} to #{fingerprint_path}" if options[:debug]
          files << asset.path
          FileUtils.cp(asset.path, fingerprint_path) if !File.exists? fingerprint_path
        end  
        
        if @@gzip
          #Update paths to fonts, PIE.htc with .gzip extension for css assets     
          asset.replace_font_gzips!(:web_host => @@web_host) if asset.css? && @@replace_font_gz
          asset.gzip!
          files.each do |file|          
            zip_name = "#{file}#{@@gz_suffix}"
            puts "Zipping #{file} to #{zip_name}" if options[:debug]
            File.open(zip_name, 'wb+') {|f| f.write(asset.data) }
          end
          #gz is served automatically if available so no need to cache in manifest
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
    
    def self.assets(paths=Asset.asset_paths)
      paths.inject([]) {|assets, path|
        path = Asset.get_absolute_path(path)        
        a = Asset.new(path)
        assets << a if a.is_file? and !a.cache_hit?
        
        assets += Dir.glob(path+'/**/*').inject([]) {|m, file|          
            a = Asset.new(file); 
          
            if @@skip_assets && a.relative_path =~ @@skip_assets
              puts "#{a.path} not included in assets" if @@debug
            elsif a.is_file? and !a.cache_hit?
              m << a 
            end
          
            m 
          }
        }
    end
    
    def self.asset_paths
      @@asset_paths
    end
    
    def self.asset_paths=(paths)
      @@asset_paths = paths
    end
    
    def self.fingerprint(path)
      asset = Asset.new(path)
      hit = Cache.get(asset)
      return hit[:fingerprint] if hit
      #Don't create new fingerprints in prod
      Rails.env.production? ? path : asset.fingerprint
    end
    
    def fingerprint
      p = relative_path
      
      #TODO: figure out when it is appropriate to return relative path
      #Used to do something like: return p if p =~ /^\/assets\//
      
      #Handle .gz files - eg. application.css.gz -> application-12345534123.css.gz 
      extension = (p =~ /#{@@gz_suffix}$/ ? File.extname(File.basename(p, @@gz_suffix)) + @@gz_suffix : File.extname(p))     
      
      File.join File.dirname(p), "#{File.basename(p, extension)}-#{md5}#{extension}"  
    end
    
    def md5
      @digest ||= Digest::MD5.hexdigest(data)
    end
    
    def mime_type
      MIME::Types.of(path).first.to_s
    end
    
    def css?
      mime_type == 'text/css'
    end
    
    def js?
      mime_type == 'application/javascript'
    end
    
    def replace_css_images!(options={})
      replace_url_tag_images!(options)
    end
    
    def replace_js_images!(options={})
      replace_src_tag_images!(options)
      options.merge! :regexp => Regexp.new(/url\((?:"(\/images[^"]*)"|'(\/images[^']*)'|(\/images[^)]*))\)/mi)
      replace_url_tag_images!(options)
    end
    
    def replace_url_tag_images!(options={})
      options[:regexp] ||= Regexp.new(/url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi)
      options.merge! :replace_with_b4_uri => "url("
      options.merge! :replace_with_after_uri => ")"
      replace_images!(options) #default
    end
    
    def replace_src_tag_images!(options={})
      options.merge! :regexp => Regexp.new(/src=(?:"(\/images[^"]*)"|'(\/images[^']*)')/mi)
      options.merge! :replace_with_b4_uri => "src=\""
      options.merge! :replace_with_after_uri => "\""
      replace_images!(options)
    end
    
    def replace_images!(options={})
      options[:asset_host] ||= ''
      options[:web_host] ||= ''
      #defaults to url tag regex
      regexp = options[:regexp] || /url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi 
      data.gsub! regexp do |match|
        begin
          # $1 is the double quoted string, $2 is single quoted, $3 is no quotes
          uri = ($1 || $2 || $3).to_s.strip
          uri.gsub!(/^\.\.\//, '/')
          
          #Important for css fixes that depend on query params and hashes          
          suffix = "" 
          pos = [uri.index("#"), uri.index("?")].compact.min
          suffix = uri.slice(pos..-1) unless pos.nil?
          
          suffix = "" if suffix =~ /\?\d{10}/ && @@remove_timestamps
                    
          b4_uri = options[:replace_with_b4_uri] || "url("
          after_uri = options[:replace_with_after_uri] || ")"
          
          original = "#{b4_uri}#{uri}#{after_uri}"
        
          # if the uri appears to begin with a protocol then the asset isn't on the local filesystem
          # uri is unchanged for data and data font uris
          if uri =~ /[a-z]+:\/\//i || uri =~ /data:/i
            original
          else
            #Skip if asset host is present in uri
            host = uri=~ /fonts/i ? options[:web_host] : options[:asset_host] 
            unless uri =~ /#{Regexp.escape(host)}/
              asset = Asset.new(uri)            
              puts "  - Changing URI #{uri} to #{host}#{asset.fingerprint}#{suffix}" if @@debug
          
              # TODO: Check the referenced asset is in the asset_paths
              # Suggested solution below. But, rescue is probably a better solution in case of nested paths and such
              # - https://github.com/KeasInc/asset_id/commit/0fbd108c06ad18f50bfa63073b2a8c5bbac154fb
              # - https://github.com/KeasInc/asset_id/commit/14ce9124938c15734ec0c61496fd371de2b8087c
              "#{b4_uri}#{host}#{asset.fingerprint}#{suffix}#{after_uri}"
            else
              original 
            end
          end
        rescue Errno::ENOENT => e
          puts "  - Warning: #{uri} not found" if @@debug
          original #TODO: Should this have asset_host?
        end
      end
    end
    
    def replace_font_gzips!(options={})
      data.gsub! /url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/mi do |match|
        begin
          uri = ($1 || $2 || $3).to_s.strip
          uri.gsub!(/^\.\.\//, '/')
                                       
          original = "url(#{uri})"
          
          if uri =~ /fonts\//mi 
            base_uri = uri
                     
            suffix = "" 
            pos = [uri.index("#"), uri.index("?")].compact.min
            unless pos.nil?
              suffix = uri.slice(pos..-1) 
              base_uri = uri.slice(0,pos)
            end
            suffix = "" if suffix =~ /\?\d{10}/ && @@remove_timestamps
                                
            puts "  - Changing URI #{uri} to #{base_uri}#{@@gz_suffix}#{suffix}" if @@debug
          
            "url(#{base_uri}#{@@gz_suffix}#{suffix})"
          else
            original
          end
        rescue Errno::ENOENT => e
          puts "  - Warning: #{uri} not found" if @@debug
          original
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
    
    def self.gzip_types
      @@gzip_types
    end
    
    def self.gzip_types=(types)
      @@gzip_types = types
    end
    
    def gzip_type?
      Asset.gzip_types.include? mime_type
    end
    
    def is_file?
      File.exists? absolute_path and !File.directory? absolute_path
    end
    
    def cache_hit?
      return false if @@nocache or Cache.miss? self
      puts "AssetID: #{relative_path} - Cache Hit" if @@debug
      return true 
    end
       
    def data
      @data ||= File.read(path)
    end
    
  end
end