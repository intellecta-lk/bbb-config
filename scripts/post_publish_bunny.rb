require 'net/http'
require 'uri'
require 'json'
require "optimist"
require File.expand_path('../../../lib/recordandplayback', __FILE__)

opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :type => String
  opt :format, "Playback format name", :type => String
end

meeting_id = opts[:meeting_id]
format = opts[:format]

# Check the format and exit silently if it's not 'video'
unless format == 'video'
  puts "Skipping Bunny Stream upload: format is '#{format}', not 'video'."
  exit 0 
end

BUNNY_LIBRARY_ID = ENV.fetch('BUNNY_STREAM_LIB_ID')
BUNNY_API_KEY = ENV.fetch('BUNNY_STREAM_API_KEY')    

logger = Logger.new("/var/log/bigbluebutton/post_publish.log", 'weekly' )
logger.level = Logger::INFO
BigBlueButton.logger = logger

meeting_metadata = BigBlueButton::Events.get_meeting_metadata("/var/bigbluebutton/recording/raw/#{meeting_id}/events.xml")
# Ensure this path is correct for your production environment
video_path = "/var/bigbluebutton/published//#{meeting_id}/video.mp4"

def get_metadata(key)
  meeting_metadata.key?(key) ? meeting_metadata[key].value : nil
end

def get_callback_url()
  meta_int_bunny_ready_url = "int-bunny-ready-url"
  callback_url = get_metadata(meta_int_bunny_ready_url)
  callback_url
end

def notify_callback(status, data)
  uri = URI(get_callback_url())
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true if uri.scheme == 'https'
  
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = { status: status, meeting_id: data[:meeting_id] }.merge(data).to_json
  http.request(request)
rescue => e
  puts "Callback failed: #{e.message}"
end


begin
  raise "Video file not found at #{video_path}" unless File.exist?(video_path)

  # STEP 1: Create Video Object
  uri = URI("https://video.bunnycdn.com/library/#{BUNNY_LIBRARY_ID}/videos")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  req = Net::HTTP::Post.new(uri, 'AccessKey' => BUNNY_API_KEY, 'Content-Type' => 'application/json')
  req.body = { title: "#{meeting_id}" }.to_json
  
  res = http.request(req)
  if res.is_a?(Net::HTTPSuccess)
    video_id = JSON.parse(res.body)['guid']
  else
        # Only try to parse the body for error messages if it's actually there
        error_msg = u_res.body.to_s.empty? ? "HTTP Error #{u_res.code}" : u_res.body
        raise "Bunny Upload Error: #{error_msg}"
  end
  
  # STEP 2: Stream Upload
  upload_uri = URI("#{uri}/#{video_id}")
  Net::HTTP.start(upload_uri.host, upload_uri.port, use_ssl: true) do |u_http|
    u_req = Net::HTTP::Put.new(upload_uri, 'AccessKey' => BUNNY_API_KEY, 'Content-Type' => 'application/octet-stream')
    File.open(video_path, 'rb') do |file|
      u_req.body_stream = file
      u_req['Content-Length'] = file.size
      u_res = u_http.request(u_req)
      
      # Check if the response code is 204 or any other 2xx success code
      if u_res.is_a?(Net::HTTPSuccess)
        # Success! No need to parse the body if it's a 204
        notify_callback('success', { meeting_id: meeting_id, bunny_id: video_id })
      else
        # Only try to parse the body for error messages if it's actually there
        error_msg = u_res.body.to_s.empty? ? "HTTP Error #{u_res.code}" : u_res.body
        raise "Bunny Upload Error: #{error_msg}"
      end
    end
  end

rescue => e
  notify_callback('fail', { meeting_id: meeting_id, reason: e.message })
  puts "Process failed for #{meeting_id}: #{e.message}"
end

