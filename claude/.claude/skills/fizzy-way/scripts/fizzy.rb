#!/usr/bin/env ruby
# Finds the Fizzy checkout the wiki cites, cloning it on first use.
#
#   ruby scripts/fizzy.rb      prints the checkout's path
#
# $FIZZY points at an existing checkout; otherwise the skill keeps its own clone
# under $XDG_CACHE_HOME (default ~/.cache)/fizzy-way/fizzy.

require "pathname"

module Fizzy
  REPOSITORY = "https://github.com/basecamp/fizzy.git"

  def self.path
    @path ||= Pathname(ENV["FIZZY"] || cache).expand_path.tap { clone(it) unless it.join(".git").exist? }
  end

  def self.cache
    File.join(ENV.fetch("XDG_CACHE_HOME", File.expand_path("~/.cache")), "fizzy-way", "fizzy")
  end

  def self.clone(path)
    abort "FIZZY=#{path} isn't a git checkout" if ENV["FIZZY"]

    warn "Cloning Fizzy into #{path}…"
    system("git", "clone", "--quiet", REPOSITORY, path.to_s, exception: true)
  end
end

puts Fizzy.path if __FILE__ == $0
