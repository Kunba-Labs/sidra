#!/usr/bin/env ruby
# frozen_string_literal: true

# App Store Connect, from the command line. The whole release is doable from the
# App Store Connect API (adapted from Kunba Labs' other apps). App privacy answers
# are the one part the API does not cover: set them once in App Store Connect.
#
#   ruby tools/asc.rb state                      what is live, what is in review
#   ruby tools/asc.rb builds                     recent uploads and their status
#   ruby tools/asc.rb version 1.0.4              create the version (AFTER_APPROVAL)
#   ruby tools/asc.rb notes 1.0.4                push description/promo/whatsNew
#   ruby tools/asc.rb shots 1.0.4 APP_IPHONE_67 dir/*.png   replace one screenshot set
#   ruby tools/asc.rb attach 1.0.4 9             attach build 9 to the version
#   ruby tools/asc.rb submit 1.0.4               send it for review
#   ruby tools/asc.rb cancel                     cancel whatever is in review
#
# Only one version may sit in review at a time; `cancel` drops the current one to
# DEVELOPER_REJECTED, which is editable, so a build can be replaced without
# burning a version number.
#
# `notes` reads store/metadata.md — the release text lives in the repo and is
# never retyped. A new version's en-US localization does not reliably inherit
# anything, so all three fields go in one PATCH regardless.

require 'digest'
require 'jwt'
require 'json'
require 'net/http'
require 'uri'

# Your App Store Connect API key, from the environment.
KEY_ID = ENV.fetch('ASC_KEY_ID') { abort 'set ASC_KEY_ID' }
ISSUER = ENV.fetch('ASC_ISSUER_ID') { abort 'set ASC_ISSUER_ID' }
APP_ID = ENV.fetch('ASC_APP_ID', '6832359499')
KEY_PATH = File.expand_path(ENV.fetch('ASC_KEY_PATH', "~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8"))
ROOT = File.expand_path('..', __dir__)
BASE = 'https://api.appstoreconnect.apple.com'

def token
  key = OpenSSL::PKey::EC.new(File.read(KEY_PATH))
  JWT.encode({ iss: ISSUER, exp: Time.now.to_i + 900, aud: 'appstoreconnect-v1' },
             key, 'ES256', { kid: KEY_ID, typ: 'JWT' })
end

def call(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post,
            patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }[method]
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.dump(body) if body
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  unless res.code.to_i.between?(200, 299)
    abort "#{method.to_s.upcase} #{path} -> #{res.code}\n#{res.body}"
  end
  res.body.to_s.empty? ? {} : JSON.parse(res.body)
end

def versions
  call(:get, "/v1/apps/#{APP_ID}/appStoreVersions?limit=10")['data']
end

def version_for(str)
  v = versions.find { |x| x['attributes']['versionString'] == str }
  abort "no appStoreVersion #{str}" unless v
  v
end

# The release notes for one version, out of store/metadata.md. Old sections stay
# in the file as a record, so the heading has to be matched exactly.
def metadata_section(heading)
  md = File.read(File.join(ROOT, 'store', 'metadata.md'))
  m = md.match(/^## #{Regexp.escape(heading)}[^\n]*\n(.*?)(?=\n## |\z)/m)
  abort "no '## #{heading}' section in store/metadata.md" unless m
  m[1].strip
end

case ARGV[0]
when 'state'
  versions.first(5).each do |v|
    a = v['attributes']
    puts format('%-8s %-22s %s', a['versionString'], a['appStoreState'], v['id'])
  end
  subs = call(:get, "/v1/apps/#{APP_ID}/reviewSubmissions?limit=5")['data']
  subs.each { |s| puts "review #{s['id']} #{s['attributes']['state']}" }

when 'builds'
  b = call(:get, "/v1/builds?filter[app]=#{APP_ID}&sort=-uploadedDate&limit=5")['data']
  b.each do |x|
    a = x['attributes']
    puts format('%-5s %-14s %s', a['version'], a['processingState'], a['uploadedDate'])
  end

when 'version'
  v = versions.find { |x| x['attributes']['versionString'] == ARGV[1] }
  if v
    puts "exists #{v['id']} #{v['attributes']['appStoreState']}"
  else
    r = call(:post, '/v1/appStoreVersions', {
               data: { type: 'appStoreVersions',
                       attributes: { platform: 'IOS', versionString: ARGV[1],
                                     releaseType: 'AFTER_APPROVAL' },
                       relationships: { app: { data: { type: 'apps', id: APP_ID } } } }
             })
    puts "created #{r['data']['id']}"
  end

when 'notes'
  v = version_for(ARGV[1])
  loc = call(:get, "/v1/appStoreVersions/#{v['id']}/appStoreVersionLocalizations")['data']
             .find { |l| l['attributes']['locale'] == 'en-US' }
  call(:patch, "/v1/appStoreVersionLocalizations/#{loc['id']}", {
         data: { type: 'appStoreVersionLocalizations', id: loc['id'],
                 attributes: { description: metadata_section('Description'),
                               promotionalText: metadata_section('Promotional text'),
                               keywords: metadata_section('Keywords'),
                               whatsNew: metadata_section("What's New (#{ARGV[1]}") } }
       })
  puts "patched #{loc['id']}"

when 'shots'
  # Replaces the set on this version only; the live version keeps its own copy.
  # Checked before anything is deleted. Deleted first because a set holds at most
  # 10, so a full set has no room for its replacements alongside it.
  files = ARGV[3..].sort
  abort 'no screenshots given' if files.empty?
  abort 'a set holds at most 10' if files.size > 10
  files.each { |f| abort "not a PNG: #{f}" unless File.file?(f) && File.binread(f, 4) == "\x89PNG".b }
  v = version_for(ARGV[1])
  loc = call(:get, "/v1/appStoreVersions/#{v['id']}/appStoreVersionLocalizations")['data']
             .find { |l| l['attributes']['locale'] == 'en-US' }
  sets = call(:get, "/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets")['data']
  set = sets.find { |s| s['attributes']['screenshotDisplayType'] == ARGV[2] }
  set ||= call(:post, '/v1/appScreenshotSets', {
                 data: { type: 'appScreenshotSets',
                         attributes: { screenshotDisplayType: ARGV[2] },
                         relationships: { appStoreVersionLocalization: {
                           data: { type: 'appStoreVersionLocalizations', id: loc['id'] } } } }
               })['data']
  call(:get, "/v1/appScreenshotSets/#{set['id']}/appScreenshots")['data'].each do |s|
    call(:delete, "/v1/appScreenshots/#{s['id']}")
  end
  files.each do |path|
    bytes = File.binread(path)
    shot = call(:post, '/v1/appScreenshots', {
                  data: { type: 'appScreenshots',
                          attributes: { fileName: File.basename(path), fileSize: bytes.size },
                          relationships: { appScreenshotSet: {
                            data: { type: 'appScreenshotSets', id: set['id'] } } } }
                })['data']
    shot['attributes']['uploadOperations'].each do |op|
      uri = URI(op['url'])
      req = Net::HTTP.const_get(op['method'].capitalize).new(uri)
      op['requestHeaders'].each { |h| req[h['name']] = h['value'] }
      req.body = bytes[op['offset'], op['length']]
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      abort "upload #{path} -> #{res.code}" unless res.code.to_i.between?(200, 299)
    end
    call(:patch, "/v1/appScreenshots/#{shot['id']}", {
           data: { type: 'appScreenshots', id: shot['id'],
                   attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(bytes) } }
         })
    puts "#{File.basename(path)} uploaded"
  end
  # Apple processes after the commit, and a bad image only fails here. Rerunning
  # with good files replaces the set; the live version keeps its own copy.
  40.times do
    states = call(:get, "/v1/appScreenshotSets/#{set['id']}/appScreenshots")['data']
             .to_h { |x| [x['attributes']['fileName'], x['attributes']['assetDeliveryState']['state']] }
    failed = states.select { |_, st| st == 'FAILED' }.keys
    abort "Apple rejected #{failed.join(', ')}: fix them and rerun shots" unless failed.empty?
    if states.size == files.size && states.values.all?('COMPLETE')
      puts "#{states.size} screenshots processed"
      exit
    end
    sleep 5
  end
  abort 'screenshots still processing after 200 s: check before submitting'

when 'attach'
  v = version_for(ARGV[1])
  build = call(:get, "/v1/builds?filter[app]=#{APP_ID}&filter[version]=#{ARGV[2]}")['data'].first
  abort "no build #{ARGV[2]}" unless build
  abort "build #{ARGV[2]} is #{build['attributes']['processingState']}" \
    unless build['attributes']['processingState'] == 'VALID'
  call(:patch, "/v1/appStoreVersions/#{v['id']}/relationships/build",
       { data: { type: 'builds', id: build['id'] } })
  puts "attached build #{ARGV[2]} (#{build['id']})"

when 'submit'
  v = version_for(ARGV[1])
  # A refused attempt leaves its empty submission open, and only one may exist.
  sub = call(:get, "/v1/apps/#{APP_ID}/reviewSubmissions?limit=10")['data']
        .find { |s| s['attributes']['state'] == 'READY_FOR_REVIEW' }
  sub ||= call(:post, '/v1/reviewSubmissions', {
                 data: { type: 'reviewSubmissions', attributes: { platform: 'IOS' },
                         relationships: { app: { data: { type: 'apps', id: APP_ID } } } }
               })['data']
  call(:post, '/v1/reviewSubmissionItems', {
         data: { type: 'reviewSubmissionItems',
                 relationships: {
                   reviewSubmission: { data: { type: 'reviewSubmissions', id: sub['id'] } },
                   appStoreVersion: { data: { type: 'appStoreVersions', id: v['id'] } }
                 } }
       })
  r = call(:patch, "/v1/reviewSubmissions/#{sub['id']}",
           { data: { type: 'reviewSubmissions', id: sub['id'],
                     attributes: { submitted: true } } })
  puts "submitted #{sub['id']} -> #{r['data']['attributes']['state']}"

when 'cancel'
  subs = call(:get, "/v1/apps/#{APP_ID}/reviewSubmissions?limit=10")['data']
  open = subs.find { |s| %w[WAITING_FOR_REVIEW IN_REVIEW READY_FOR_REVIEW].include?(s['attributes']['state']) }
  abort 'nothing in review' unless open
  r = call(:patch, "/v1/reviewSubmissions/#{open['id']}",
           { data: { type: 'reviewSubmissions', id: open['id'],
                     attributes: { canceled: true } } })
  puts "cancelled #{open['id']} -> #{r['data']['attributes']['state']}"

else
  abort File.read(__FILE__).lines[2..25].join
end
