#!/usr/bin/env ruby
# Prints the silhouette of a Ruby file: how long each method is, in file order.
# Shape is the one dimension omakase declines to police, so read it with your eyes.

files = ARGV.reject { |a| a.start_with?("-") }
abort "usage: shape.rb FILE.rb [FILE.rb ...]" if files.empty?

def methods_in(node, found = [])
  return found unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  if %i[DEFN DEFS].include?(node.type)
    name = node.children.find { |c| c.is_a?(Symbol) }
    prefix = node.type == :DEFS ? "self." : ""
    found << [ "#{prefix}#{name}", node.first_lineno, node.last_lineno ]
  end
  node.children.each { |child| methods_in(child, found) }
  found
end

unreadable = false

files.each do |file|
  lines = File.readlines(file)
  code = lines.reject { |l| l.strip.empty? || l.strip.start_with?("#") }
  comments = lines.count { |l| l.strip.start_with?("#") }
  blanks = lines.count { |l| l.strip.empty? }
  deepest = code.max_by { |l| l[/\A */].size }
  indent = deepest[/\A */].size / 2
  indent_line = lines.index(deepest).succ
  cut = lines.index { |l| l.strip == "private" }&.succ

  methods = methods_in(RubyVM::AbstractSyntaxTree.parse_file(file)).sort_by(&:last)
  lengths = methods.map { |_, a, b| b - a + 1 }
  public_count, private_count = methods.partition { |_, a, _| cut.nil? || a < cut }.map(&:size)

  puts "#{file} — #{lines.size} lines (#{comments * 100 / lines.size}% comment, " \
       "#{blanks * 100 / lines.size}% blank), deepest indent #{indent} at :#{indent_line}"
  puts "  #{methods.size} methods (#{public_count} public, #{private_count} private), " \
       "median #{lengths.empty? ? 0 : lengths.sort[lengths.size / 2]} lines, longest #{lengths.max || 0}"
  puts
  methods.each do |name, first, last|
    length = last - first + 1
    puts format("  %5d  %-38s %s %d", first, name, "█" * [ length, 60 ].min, length)
  end
  puts
rescue SyntaxError, SystemCallError => e
  warn "shape.rb: #{file} isn't parseable Ruby — #{e.message.lines.first.strip}"
  unreadable = true
end

exit 1 if unreadable
