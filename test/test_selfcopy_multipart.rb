$: << File.expand_path('../lib', __dir__)

require 'net/http'
require 'rexml/document'
require 'test/unit'
require 'tmpdir'
require 'emulator/server'

# Standalone test (stdlib + builder/webrick only, no aliyun-sdk):
#   docker run --rm -v "$PWD":/work -w /work dandalf/oss-emulator:1.1 ruby test/test_selfcopy_multipart.rb
#
# CopyObject onto the same key is the OSS metadata-update mechanism, and CopyObject
# with x-oss-metadata-directive=REPLACE rebuilds metadata from the request. Neither
# may recompute :size/:md5 from the first part file of a multipart object.
module OssEmulator

  class TestSelfCopyMultipart < Test::Unit::TestCase
    HOST = '127.0.0.1'
    PORT = 4568
    BUCKET = 'bucket-selfcopy-multipart'
    PART_ONE = 'a' * 1024
    PART_TWO = 'b' * 512
    TOTAL_SIZE = PART_ONE.bytesize + PART_TWO.bytesize

    class << self
      def startup
        Log.init('/tmp/oss-emulator-selfcopy-test.log')
        Config.init
        Config.set_store(Dir.mktmpdir('oss-emulator-store'))

        @server = Server.new(HOST, PORT, HttpMsg::HOST, nil, nil, quiet: true)
        @server_thread = Thread.new { @server.serve }
        wait_for_server

        response = Net::HTTP.start(HOST, PORT) { |http| http.request(Net::HTTP::Put.new("/#{BUCKET}")) }
        raise "create bucket failed : #{response.code} #{response.body}" unless response.code == '200'
      end

      def shutdown
        @server.shutdown
        @server_thread.join
      end

      def wait_for_server
        deadline = Time.now + 10
        begin
          TCPSocket.new(HOST, PORT).close
        rescue Errno::ECONNREFUSED
          raise "emulator did not start on #{HOST}:#{PORT}" if Time.now > deadline
          sleep 0.1
          retry
        end
      end
    end

    def test_self_copy_preserves_multipart_size
      object = 'object-multipart-self-copy'
      upload_multipart(object)
      assert_equal(TOTAL_SIZE, head_content_length(object))

      response = copy_replace(object, object)
      assert_equal('200', response.code, response.body)

      assert_equal(TOTAL_SIZE, head_content_length(object),
                   'metadata-only self-copy must not change the size of a multipart object')

      head = request(Net::HTTP::Head.new("/#{BUCKET}/#{object}"))
      assert_equal('1751895000', head['x-oss-meta-mtime'],
                   'self-copy must apply the replacement custom metadata')

      get = request(Net::HTTP::Get.new("/#{BUCKET}/#{object}"))
      assert_equal('200', get.code)
      assert_equal(PART_ONE + PART_TWO, get.body,
                   'self-copy must leave the multipart content intact')
    end

    def test_get_streams_all_multipart_parts
      object = 'object-multipart-get'
      upload_multipart(object)

      get = request(Net::HTTP::Get.new("/#{BUCKET}/#{object}"))
      assert_equal('200', get.code)
      assert_equal(TOTAL_SIZE.to_s, get['Content-Length'])
      assert_equal(PART_ONE + PART_TWO, get.body,
                   'GET must concatenate every part of a multipart object')
    end

    def test_range_get_spans_multipart_parts
      object = 'object-multipart-range'
      upload_multipart(object)

      get = Net::HTTP::Get.new("/#{BUCKET}/#{object}")
      get['Range'] = 'bytes=1000-1099'
      response = request(get)
      assert_equal('206', response.code)
      assert_equal("bytes 1000-1099/#{TOTAL_SIZE}", response['Content-Range'])
      assert_equal(('a' * 24) + ('b' * 76), response.body,
                   'a ranged GET must read across part boundaries')
    end

    def test_copy_replace_preserves_multipart_size
      object_src = 'object-multipart-copy-src'
      object_dst = 'object-multipart-copy-dst'
      upload_multipart(object_src)

      response = copy_replace(object_src, object_dst)
      assert_equal('200', response.code, response.body)

      assert_equal(TOTAL_SIZE, head_content_length(object_dst),
                   'REPLACE-directive copy of a multipart object must report the full size')
    end

    def test_copy_and_self_copy_of_single_part_object
      object = 'object-single'
      body = 'c' * 2048
      put = Net::HTTP::Put.new("/#{BUCKET}/#{object}")
      put['Content-Type'] = 'application/octet-stream'
      put.body = body
      assert_equal('200', request(put).code)

      response = copy_replace(object, object)
      assert_equal('200', response.code, response.body)
      assert_equal(body.bytesize, head_content_length(object))

      response = copy_replace(object, 'object-single-copy')
      assert_equal('200', response.code, response.body)
      assert_equal(body.bytesize, head_content_length('object-single-copy'))

      get = request(Net::HTTP::Get.new("/#{BUCKET}/object-single-copy"))
      assert_equal('200', get.code)
      assert_equal(body, get.body)
    end

    private

    def request(req)
      Net::HTTP.start(HOST, PORT) { |http| http.request(req) }
    end

    def upload_multipart(object)
      response = request(Net::HTTP::Post.new("/#{BUCKET}/#{object}?uploads"))
      assert_equal('200', response.code, response.body)
      upload_id = REXML::Document.new(response.body).elements['//UploadId'].text

      [PART_ONE, PART_TWO].each_with_index do |part, index|
        put = Net::HTTP::Put.new("/#{BUCKET}/#{object}?partNumber=#{index + 1}&uploadId=#{upload_id}")
        # Without an explicit content type, Net::HTTP sends x-www-form-urlencoded and
        # WEBrick consumes the body as form data before the emulator can store it.
        put['Content-Type'] = 'application/octet-stream'
        put.body = part
        assert_equal('200', request(put).code)
      end

      complete = Net::HTTP::Post.new("/#{BUCKET}/#{object}?uploadId=#{upload_id}")
      complete['Content-Type'] = 'application/xml'
      complete.body = <<~XML
        <CompleteMultipartUpload>
          <Part><PartNumber>1</PartNumber></Part>
          <Part><PartNumber>2</PartNumber></Part>
        </CompleteMultipartUpload>
      XML
      assert_equal('200', request(complete).code)
    end

    def copy_replace(src_object, dst_object)
      put = Net::HTTP::Put.new("/#{BUCKET}/#{dst_object}")
      put['x-oss-copy-source'] = "/#{BUCKET}/#{src_object}"
      put['x-oss-metadata-directive'] = 'REPLACE'
      put['x-oss-meta-mtime'] = '1751895000'
      put['Content-Type'] = 'application/octet-stream'
      put.body = ''
      request(put)
    end

    def head_content_length(object)
      response = request(Net::HTTP::Head.new("/#{BUCKET}/#{object}"))
      assert_equal('200', response.code)
      response['Content-Length'].to_i
    end

  end # class
end # module
