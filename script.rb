require "ruby_lsp/internal"

config = RubyIndexer::Configuration.new
uris = config.indexable_uris

# Now inspect the URIs and see if they include Active Support Test Case and so on

result = uris.find do |uri|
  uri.full_path.end_with?("notes_controller_test.rb")
end

if result
  puts "Found the file: #{result.full_path}"
else
  puts "File not found in the indexable URIs."
  puts uris.filter { |uri| uri.full_path.include?("debug_ruby_lsp/test") }.map(&:full_path)
end
