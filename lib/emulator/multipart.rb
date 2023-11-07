require 'builder'
require 'securerandom'
require "rexml/document"  
require 'emulator/config'
require 'emulator/util'
require 'emulator/response'
include REXML
include Comparable

module OssEmulator
  module Multipart
    
    # InitiateMultipartUpload
    def self.initiate_multipart_upload(bucket, object, response)
      # NoSuchBucket
      return if OssResponse.response_no_such_bucket(response, bucket)

      # delete object
      OssUtil.delete_object_file_and_dir(bucket, object)

      dataset = {
        cmd: Request::POST_INIT_MULTIPART_UPLOAD,
        bucket: bucket,
        object: object,
        upload_id: SecureRandom.hex
      }

      OssResponse.response_ok(response, dataset)
    end

    # UploadPart
    def self.upload_part(req, query, request, response) 
      part_number   = query['partNumber'].first

      Object.put_object(req.bucket, req.object, request, response, part_number)
    end

    # CompleteMultipartUpload
    def self.complete_multipart_upload(req, request, response)
      parts = []
      xml = Document.new(request.body)
      Log.info("Complete multipart body: #{xml}")
      xml.elements.each("*/Part") do |e| 
        part = {}
        part[:number] = e.elements["PartNumber"].text
        parts << part
      end
      
      object_dir = File.join(Config.store, req.bucket, req.object)
      base_obj_part_filename = File.join(object_dir, Store::OBJECT_CONTENT_PREFIX)
      complete_file_size = 0

      Dir.glob(base_obj_part_filename + "*").each do |file|
        complete_file_size += File.size(file)
      end

      options = { :size => complete_file_size, :part_size => File.size(File.join(object_dir, Store::OBJECT_CONTENT)) }
      dataset = OssUtil.put_object_metadata(req.bucket, req.object, request, options)

      dataset[:cmd] = Request::POST_COMPLETE_MULTIPART_UPLOAD
      dataset[:object] = req.object
      OssResponse.response_ok(response, dataset)
    end #function

  end # class
end # module
