require 'rubygems'
require 'zip'
require 'digest'
require 'firebase'

base_uri = 'https://navit.firebaseio.com/'
firebase = Firebase::Client.new(base_uri)

Zip::File.open('~/assets/california-latest.bin') do |zip_file|
  # Handle entries one by one
  zip_file.each do |entry|
    puts "Hashing #{entry.name}"
    # Read into memory
    content = entry.get_input_stream.read
    md5 = Digest::MD5.new
    md5 << content

    response = firebase.set(entry.name, { :hash => md5.hexdigest })
  end
end
