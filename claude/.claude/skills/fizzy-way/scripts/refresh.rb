#!/usr/bin/env ruby
# Keeps the wiki current with Fizzy. Every page pins the commit it was verified at
# (snapshot:) and lists what it was distilled from (sources:), so staleness is per page.
#
#   refresh.rb                  report stale pages, uncovered code, and new commits
#   refresh.rb --diff PAGE...   what changed upstream in the files those pages cite
#   refresh.rb --bump-clean     advance pages whose sources didn't change to upstream
#   refresh.rb --mark PAGE...   advance pages you've just updated (paths relative to wiki/)
#   refresh.rb --verify         every cited SHA, quoted commit subject, and path checks out
#   refresh.rb --evidence       append new DHH and team commits to wiki/evidence/
#
# Refreshing is the only time the skill needs Fizzy's code: each run clones it into a
# temporary directory and deletes it on exit. Nothing is assumed about the machine.

require "pathname"
require "tmpdir"
require "fileutils"
require "set"

REPOSITORY = "https://github.com/basecamp/fizzy"
WIKI = Pathname(__dir__).join("../wiki").expand_path
UPSTREAM = "origin/main"
PATH = %r{\A(?:app|config|db|lib|test|saas|bin|script|docs)/\S+|\A(?:STYLE|AGENTS|README)\.md\z|\AGemfile\z|\A\.rubocop\.yml\z}
TEAM = /Jorge Manrubia|Mike Dalessio|Kevin McConnell|Stanko|Rosa Gutierrez|Jeremy Daer|Jeffrey Hardy|Donal McBreen|Jose Farias/

# A fresh clone on first use, deleted when the run ends.
def fizzy
  @fizzy ||= Pathname(Dir.mktmpdir("fizzy-way")).join("fizzy").tap do |path|
    at_exit { FileUtils.rm_rf(path.dirname) }
    system("git", "clone", "--quiet", "#{REPOSITORY}.git", path.to_s, exception: true)
  end
end

def git(*args)
  IO.popen([ "git", "-C", fizzy.to_s, *args ], err: File::NULL, &:read).to_s
end

class Page
  attr_reader :path, :text

  def self.all
    Dir.glob(WIKI.join("{components,patterns,testing,voice,decisions}/**/*.md")).sort.map { new(it) }
  end

  def initialize(path)
    @path = Pathname(path)
    @text = File.read(path)
  end

  def name = path.relative_path_from(WIKI).to_s

  # Frontmatter isn't parsed as YAML: use_when lists carry free-form quotes. Only these two fields matter here.
  def frontmatter = text[/\A---\n(.*?)\n---/m, 1].to_s

  def snapshot = frontmatter[/^snapshot: ([0-9a-f]{7,40})/, 1]

  def sources
    inline = frontmatter[/^sources: (\S.*)$/, 1]
    listed = frontmatter[/^sources:\n((?:  .*\n?)+)/, 1].to_s.lines.map { it.sub(/\A\s*-\s*/, "").strip }
    [ inline, *listed ].compact
  end

  # Repo paths and globs this page depends on: its sources: list plus paths cited in backticks.
  def cited_paths
    listed = sources.flat_map { it.split(/,\s*/) }.map { it.strip.sub(/\s*\(.*\z/, "") }
    inline = text.scan(/`([^`\s]+)`/).flatten
    (listed + inline).map { it.delete_suffix(":") }.grep(PATH).uniq
  end

  def cites?(file)
    cited_paths.any? do |pattern|
      pattern.end_with?("/**", "/") ? file.start_with?(pattern.delete_suffix("**")) :
        File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_EXTGLOB) || File.fnmatch?(pattern.sub("/**", "/**/*"), file, File::FNM_PATHNAME)
    end
  end

  def advance_to(sha)
    text.sub!(/^snapshot: \S+/, "snapshot: #{sha}")
    path.write(text)
  end
end

# Changed files between two commits as { path => status }; a rename counts as its old path deleted.
def changes(from, to)
  git("diff", "--name-status", "-M", from, to).lines.each_with_object({}) do |line, changed|
    status, *paths = line.chomp.split("\t")
    if status.start_with?("R")
      changed[paths.first] = "D"
      changed[paths.last] = "A"
    else
      changed[paths.first] = status
    end
  end
end

def upstream_sha
  @upstream_sha ||= git("rev-parse", "--short=9", UPSTREAM).strip
end

def report
  target = upstream_sha
  pages = Page.all
  puts "Fizzy #{UPSTREAM} is at #{target}."

  stale = pages.filter_map do |page|
    next if page.snapshot.nil? || page.snapshot.start_with?(target)

    touched = changes(page.snapshot, target).select { |file, _| page.cites?(file) }
    [ page, touched ] if touched.any?
  end

  puts
  if pages.all? { it.snapshot.nil? || it.snapshot.start_with?(target) }
    puts "Every page is at #{target}. Up to date."
  elsif stale.empty?
    puts "No page's sources changed. Run --bump-clean to advance them all to #{target}."
  else
    puts "Stale pages (#{stale.size}) — update, then --mark them:"
    stale.each do |page, touched|
      puts "  #{page.name}  #{REPOSITORY}/compare/#{page.snapshot}...#{target}"
      touched.each { |file, status| puts "    #{status == "D" ? "DELETED (citation broken)" : status} #{file}" }
    end
  end

  oldest = pages.filter_map(&:snapshot).uniq
  everything = oldest.flat_map { changes(it, target).keys }.uniq
  uncovered = everything.grep(%r{\Aapp/(models|controllers|jobs)/}).reject { |file| pages.any? { it.cites?(file) } }
  if uncovered.any?
    puts
    puts "Changed app code no page cites (candidates for a new page or a sources: entry):"
    uncovered.group_by { File.dirname(it) }.each { |dir, files| puts "  #{dir}/ #{files.map { File.basename(it) }.join(", ")}" }
  end

  since = oldest.min_by { git("log", "-1", "--format=%ct", it).to_i }
  commits = git("log", "--no-merges", "--format=%h %ad %an: %s", "--date=short", "#{since}..#{target}").lines
  dhh = commits.grep(/David Heinemeier Hansson/)
  team = commits.grep(TEAM)
  puts
  puts "New commits since #{since}: #{commits.size} (DHH #{dhh.size}, core team #{team.size})."
  dhh.first(15).each { puts "  DHH #{it.split(" ", 2).first} #{it[/: (.*)/, 1]}" }
  puts "  Read these against voice/dhh-refactors.md; run --evidence to append them to wiki/evidence/." if dhh.any? || team.any?
end

def diff(names)
  target = upstream_sha
  names.each do |name|
    page = Page.new(WIKI.join(name))
    files = changes(page.snapshot, target).keys.select { page.cites?(it) }
    puts "### #{page.name}: #{page.snapshot}..#{target}"
    puts files.any? ? git("diff", page.snapshot, target, "--", *files) : "(no cited file changed)"
  end
end

def bump_clean
  target = upstream_sha
  Page.all.each do |page|
    next if page.snapshot.nil? || page.snapshot.start_with?(target)

    if changes(page.snapshot, target).none? { |file, _| page.cites?(file) }
      page.advance_to(target)
      puts "advanced #{page.name}"
    end
  end
  advance_index
end

def mark(names)
  target = upstream_sha
  names.each do |name|
    page = Page.new(WIKI.join(name))
    page.advance_to(target)
    puts "marked #{page.name} at #{target}"
  end
  advance_index
end

# index.md shows the oldest snapshot any page is still pinned to.
def advance_index
  oldest = Page.all.filter_map(&:snapshot).uniq.min_by { git("log", "-1", "--format=%ct", it).to_i }
  date = git("log", "-1", "--format=%cs", oldest).strip
  index = WIKI.join("index.md")
  index.write(index.read.sub(/^snapshot: .*$/, "snapshot: #{oldest} (oldest page; basecamp/fizzy main, #{date})"))
end

def verify
  problems = Page.all.flat_map do |page|
    found = []

    page.text.scan(/\b[0-9a-f]{9}\b/).uniq.each do |sha|
      found << "#{page.name}: SHA #{sha} not found" if git("cat-file", "-t", sha).strip != "commit"
    end

    page.text.scan(/\b([0-9a-f]{9}) "((?:[^"\\]|\\.)+)"/).each do |sha, quoted|
      subject = git("log", "-1", "--format=%s", sha).strip
      next if subject.empty? || subject.gsub(/\s+/, " ") == quoted.gsub('\"', '"').gsub(/\s+/, " ")
      found << "#{page.name}: #{sha} quoted as \"#{quoted}\" but is \"#{subject}\"" unless subject.include?('"')
    end

    # Placeholders (<model>) and service-layer dirs (cited as what Fizzy doesn't have) aren't claims about the tree;
    # a path that existed earlier in history is cited as moved or removed.
    tree = git("ls-tree", "-r", "--name-only", page.snapshot.to_s).lines.map(&:chomp).to_set
    page.cited_paths.reject { it.match?(/[*{<]/) || it.match?(%r{\Aapp/(services|interactors|operations|commands|repositories)\b}) }.each do |path|
      present = tree.include?(path.delete_suffix("/")) || tree.any? { it.start_with?(path.end_with?("/") ? path : "#{path}/") }
      historical = !present && !git("log", "-1", "--format=%h", "--all", "--", path).strip.empty?
      found << "#{page.name}: #{path} not in #{page.snapshot}, and never was" unless present || historical
    end

    found
  end

  puts problems.empty? ? "All citations check out." : problems
  exit(problems.empty? ? 0 : 1)
end

def append_evidence
  target = upstream_sha
  { "dhh-commits.txt" => [ "%h %ad %s", /David Heinemeier Hansson/ ], "team-commits.txt" => [ "%h %ad %an: %s", TEAM ] }.each do |file, (format, author)|
    path = WIKI.join("evidence", file)
    newest = path.read.lines.first.to_s.split.first
    lines = git("log", "--no-merges", "--format=#{format}|%an", "--date=short", "#{newest}..#{target}").lines
      .select { it.split("|").last.match?(author) }.map { "#{it.rpartition("|").first}\n" }
    path.write(lines.join + path.read) if lines.any?
    puts "#{file}: #{lines.size} new"
  end
end

if __FILE__ == $0
  case ARGV.first
  when "--diff"       then diff(ARGV.drop(1))
  when "--bump-clean" then bump_clean
  when "--mark"       then mark(ARGV.drop(1))
  when "--verify"     then verify
  when "--evidence"   then append_evidence
  else report
  end
end
