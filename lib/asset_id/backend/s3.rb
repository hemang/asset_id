require 'aws'

module AssetID
  class S3
  
    def self.s3_config
      @@config ||= YAML.load_file(File.join(Rails.root, "config/asset_id.yml"))[Rails.env] rescue nil || {}
    end
  
    def self.connect_to_s3
      AWS.config(:logger => Rails.logger)
      AWS.config(:access_key_id => s3_config['access_key_id'],
      :secret_access_key => s3_config['secret_access_key']
      )
      AWS::S3.new
    end
  
    def self.s3_permissions
      s3_config['permissions'] || :public_read
    end
  
    def self.s3_bucket
      s3_config['bucket']
    end
    
    def self.s3_folder
      s3_config['folder']
    end
    
    def self.s3_prefix
      s3_config['prefix'] || s3_bucket_url
    end
    
    def self.s3_bucket_url
      "http://#{s3_bucket}.s3.amazonaws.com#{s3_folder ? "/#{s3_folder}" : '' }"
    end
    
    def self.full_path(asset)
      s3_folder ? "/#{s3_folder}#{asset.fingerprint}" : asset.fingerprint
    end
    
    def gzip_headers
      {:content_encoding => 'gzip'}
    end
    
    def self.upload(options={})
      Asset.init(:debug => options[:debug], :nofingerprint => options[:nofingerprint])
      
      assets = Asset.find
      return if assets.empty?
    
      s3 = connect_to_s3
              
      bucket = s3.bucket[s3_bucket]
      
      # If the bucket doesn't exist, create it. Errors handled by lib, nice!
      unless bucket.exists?
          s3.buckets.create(s3_bucket)
      end
      
      assets.each do |asset|
      
        puts "AssetID: #{asset.relative_path}" if options[:debug]
      
        headers = {
          :content_type => asset.mime_type,
          :acl => s3_permissions,
        }.merge(asset.cache_headers)
        
        asset.replace_css_images!(:prefix => s3_prefix) if asset.css?
        
        if asset.gzip_type?
          headers.merge!(gzip_headers)
          asset.gzip!
        end
        
        if options[:debug]
          puts "  - Uploading: #{full_path(asset)} [#{asset.data.size} bytes]"
          puts "  - Headers: #{headers.inspect}"
        end
        
        unless options[:dry_run]
          res = bucket.objects[full_path(asset)].write(
            asset.data,
            headers
          ) 
          puts "  - Response: #{res.inspect}" if options[:debug]
        end
      end
    
      Cache.save! unless options[:dry_run]
    end
  
  end
end