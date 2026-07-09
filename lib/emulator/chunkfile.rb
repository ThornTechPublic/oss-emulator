require 'time'
require 'emulator/base'

module OssEmulator

  class ChunkFile < File
    attr_accessor :options

    def self.open(filename, options = {})
      file_handle = super(filename, 'rb')
      file_handle.options = options
      file_handle.options[:cur_pos] = 0
      file_handle.options[:bytes_left_to_read] = options[:read_length]
      file_handle.options[:base_part_filename] = options[:base_part_filename]
      file_handle.options[:part_number] = 1
      file_handle.options[:f_part] = nil
      file_handle.options[:request_id] = options[:request_id]

      Log.debug("ChunkFile.open :#{file_handle.options[:base_part_filename]}#{file_handle.options[:part_number]}, #{file_handle.options[:type]}, #{file_handle.options}", 'blue')
      return file_handle
    end

    def read(args)
      case self.options[:type] 
      when 'single_whole'
        return super(Object::STREAM_CHUNK_SIZE)

      when 'single_range'
        return nil if self.options[:bytes_left_to_read] <= 0
        self.pos = self.options[:start_pos] if self.options[:cur_pos] == 0

        bytes_cur_to_read = (self.options[:bytes_left_to_read] <= Object::STREAM_CHUNK_SIZE) ? self.options[:bytes_left_to_read] : Object::STREAM_CHUNK_SIZE
        self.options[:bytes_left_to_read] -= bytes_cur_to_read
        return super(bytes_cur_to_read)

      # Multipart objects are streamed by OssResponse.multipart_content_body:
      # WEBrick >= 1.7 sends IO bodies with IO.copy_stream, which never calls
      # this Ruby-level read override, so ChunkFile can only serve single-file
      # objects (where native streaming of the underlying file is correct).
      else
        return nil
      end # when

      return nil
    end # func read

  end # class ChunkFile

end # OssEmulator
