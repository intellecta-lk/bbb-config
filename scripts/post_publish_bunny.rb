#!/usr/bin/ruby
# encoding: UTF-8

#
# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
#
# Copyright (c) 2012 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU Lesser General Public License as published by the Free
# Software Foundation; either version 3.0 of the License, or (at your option)
# any later version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more
# details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.
#

require 'net/http'
require 'json'
require "optimist"
require File.expand_path('../../../lib/recordandplayback', __FILE__)

opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :type => String
  opt :format, "Playback format name", :type => String
end

meeting_id = opts[:meeting_id]
format = opts[:format]

logger = Logger.new("/var/log/bigbluebutton/post_publish.log", 'weekly' )
logger.level = Logger::INFO
BigBlueButton.logger = logger
BigBlueButton.logger.info("Start Uploading To Bunny For Meeting Id #{meeting_id}")

unless format == 'video'
  puts "Skipping Bunny Stream upload: format is '#{format}', not 'video'."
  exit 0 
end

BUNNY_LIBRARY_ID = ENV.fetch('BUNNY_STREAM_LIB_ID')
BUNNY_API_KEY = ENV.fetch('BUNNY_STREAM_API_KEY')    



meeting_metadata = BigBlueButton::Events.get_meeting_metadata("/var/bigbluebutton/recording/raw/#{meeting_id}/events.xml")

# UPDATED: Correct production path for BBB video recordings
video_path = "/var/bigbluebutton/published/video/#{meeting_id}/video-0.m4v"

def get_metadata(key, meeting_metadata)
  meeting_metadata.key?(key) ? meeting_metadata[key].value : nil
end

# Helper to convert bytes to KB, MB, GB etc.
def format_bytes(bytes)
  units = ['B', 'KB', 'MB', 'GB', 'TB']
  return "0 B" if bytes == 0
  exp = (Math.log(bytes) / Math.log(1024)).to_i
  exp = units.size - 1 if exp > units.size - 1
  "#{'%.2f' % (bytes.to_f / 1024**exp)} #{units[exp]}"
end

def notify_callback(status, data, meeting_metadata)
  meta_int_bunny_ready_url = "int-bunny-ready-url"
  callback_url = get_metadata(meta_int_bunny_ready_url, meeting_metadata)
  return unless callback_url

  uri = URI(callback_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true if uri.scheme == 'https'
  
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  # Merging all data into the payload
  request.body = { status: status }.merge(data).to_json
  http.request(request)
rescue => e
  puts "Callback failed: #{e.message}"
  BigBlueButton.logger.info( "Callback failed: #{e.message}")
end

begin
  raise "Video file not found at #{video_path}" unless File.exist?(video_path)
  
  file_size_bytes = File.size(video_path)
  human_size = format_bytes(file_size_bytes)

  # STEP 1: Create Video Object
  uri = URI.parse("https://video.bunnycdn.com/library/#{BUNNY_LIBRARY_ID}/videos")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  req = Net::HTTP::Post.new(uri, 'AccessKey' => BUNNY_API_KEY, 'Content-Type' => 'application/json')
  req.body = { title: "BBB Recording #{meeting_id}" }.to_json
  
  res = http.request(req)
  if res.is_a?(Net::HTTPSuccess)
    video_id = JSON.parse(res.body)['guid']
  else
    raise "Bunny Create Error: #{res.body}"
  end
  
  # STEP 2: Stream Upload
  upload_uri = URI.parse("#{uri}/#{video_id}")
  start_time = Time.now

  Net::HTTP.start(upload_uri.host, upload_uri.port, use_ssl: true) do |u_http|
    u_req = Net::HTTP::Put.new(upload_uri, 'AccessKey' => BUNNY_API_KEY, 'Content-Type' => 'application/octet-stream')
    File.open(video_path, 'rb') do |file|
      u_req.body_stream = file
      u_req['Content-Length'] = file_size_bytes
      u_res = u_http.request(u_req)
      
      if u_res.is_a?(Net::HTTPSuccess)
        duration = (Time.now - start_time).round(2)

        notify_callback('success', { 
          meeting_id: meeting_id, 
          bunny_id: video_id,
          file_size_raw: file_size_bytes,
          file_size_readable: human_size,
          upload_duration_seconds: duration
        }, meeting_metadata)
      else
        raise "Bunny Upload Error: #{u_res.body}"
      end
    end
  end

rescue => e
  notify_callback('fail', { meeting_id: meeting_id, reason: e.message }, meeting_metadata)
  puts "Process failed: #{e.message}"
  BigBlueButton.logger.info("Process failed: #{e.message}")
end