#!/usr/bin/env ruby
# Flags the shapes 37signals corrects, each pointing at the wiki page that shows the alternative.
# Candidates, not verdicts: every check is calibrated so Fizzy itself comes out (nearly) clean.
#
# Stateless: every run reads the code as it is. Judge each candidate against the project's own directives.
#
#   check.rb [ROOT]                  whole app
#   check.rb [ROOT] --paths a.rb b/  only findings in these paths
#   check.rb [ROOT] --since REF      what changed against a git ref: new and fixed findings
#   check.rb [ROOT] --next [N]       rank findings by weight × churn × size; the theme to take on next
#   check.rb --shape FILE...         neutral per-file readout, no judgments

require "prism"
require "pathname"
require "tmpdir"

CRUD = %w[ index show new create edit update destroy ].freeze

# URLs an external spec fixes, in any app: they can't be reshaped into resources.
PROTOCOL_ACTIONS = {
  /well_known/ => :any,
  /saml/       => %w[ acs metadata ],
  /pwa/        => %w[ service_worker manifest ],
  /auth|oauth/ => %w[ token authorize revoke introspect ]
}.freeze

def protocol?(controller, action)
  PROTOCOL_ACTIONS.any? { |pattern, actions| controller.match?(pattern) && (actions == :any || actions.include?(action)) }
end
LAYER_SUFFIXES = %w[ Service Manager Interactor Handler Operation Command Repository UseCase ].freeze
LAYER_DIRS = %w[ services interactors operations commands repositories use_cases ].freeze

# subject names what was found (an action, a column, a method) so a finding keeps its id when lines shift.
Finding = Struct.new(:check, :path, :line, :message, :subject) do
  def id
    [ check.name, path, subject ].compact.join(" ")
  end
end

Check = Struct.new(:name, :page, :question, :runner)

class String
  def squish = strip.gsub(/\s+/, " ")
  def presence = (self unless empty?)
end

class Repo
  attr_reader :root

  def initialize(root)
    @root = Pathname(root).expand_path
  end

  def files(glob)
    Dir.glob(root.join(glob).to_s).sort.map { Pathname(it) }
  end

  def relative(path)
    Pathname(path).relative_path_from(root).to_s
  end

  def parse(path)
    (@parsed ||= {})[path.to_s] ||= Prism.parse_file(path.to_s).value
  end

  def source(path)
    (@sources ||= {})[path.to_s] ||= File.read(path)
  end

  # Each route as [statement, line], with wrapped arguments joined onto their first line.
  def routes
    path = root.join("config/routes.rb")
    return [] unless path.exist?

    File.readlines(path).each_with_index.each_with_object([]) do |(line, index), joined|
      if joined.any? && joined.last.first.rstrip.end_with?(",")
        joined.last[0] = joined.last.first.rstrip + " " + line.strip
      else
        joined << [ line, index + 1 ]
      end
    end
  end

  def toplevel
    @toplevel ||= Pathname(`git -C #{root} rev-parse --show-toplevel 2>/dev/null`.strip.presence || root)
  end

  def schema
    path = root.join("db/schema.rb")
    path.exist? ? File.read(path) : ""
  end
end

# Walks a class body, yielding each def with its visibility.
def each_def(node, visibility = :public, &block)
  return unless node

  statements =
    case node
    when Prism::StatementsNode then node.body
    when Prism::ClassNode, Prism::ModuleNode then node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
    else []
    end

  statements.each do |child|
    case child
    when Prism::CallNode
      visibility = child.name if %i[ private protected public ].include?(child.name) && child.arguments.nil?
    when Prism::DefNode
      yield child, visibility
    when Prism::ClassNode, Prism::ModuleNode
      each_def(child, :public, &block)
    end
  end
end

def body_statements(definition)
  case body = definition.body
  when Prism::StatementsNode then body.body
  when nil then []
  else [ body ]
  end
end

def calls_in(call)
  call.is_a?(Prism::CallNode) ? [ call, *calls_in(call.receiver) ] : []
end

def classes_in(tree)
  found = []
  walk = ->(node) do
    found << node if node.is_a?(Prism::ClassNode)
    node.compact_child_nodes.each { walk.(it) }
  end
  walk.(tree)
  found
end

CHECKS = [
  Check.new("service-layer", "patterns/model-concerns",
    "Is this a layer Rails already has a place for — a model trait, a PORO under the model's namespace?",
    ->(repo) do
      dirs = LAYER_DIRS.flat_map { repo.files("app/#{it}/**/*.rb") }.map do |path|
        Finding.new(nil, repo.relative(path), 1, "lives in a service-layer directory")
      end

      named = repo.files("app/**/*.rb").flat_map do |path|
        classes_in(repo.parse(path)).filter_map do |klass|
          name = klass.constant_path.slice
          if LAYER_SUFFIXES.any? { name.end_with?(it) } && !path.to_s.include?("/app/jobs/")
            Finding.new(nil, repo.relative(path), klass.location.start_line, "#{name} names a role, not a domain concept", name)
          end
        end
      end

      dirs + named
    end),

  Check.new("custom-action", "patterns/state-as-resource",
    "Could this action be create/destroy on a nested singular resource (resource :closure, not post :close)?",
    ->(repo) do
      repo.files("app/controllers/**/*_controller.rb").flat_map do |path|
        next [] if path.basename.to_s == "application_controller.rb"

        findings = []
        each_def(repo.parse(path).statements) do |definition, visibility|
          action = definition.name.to_s
          if visibility == :public && definition.receiver.nil? && !CRUD.include?(action) && !protocol?(path.to_s, action)
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "public action ##{definition.name}", "##{definition.name}")
          end
        end
        findings
      end
    end),

  Check.new("custom-route", "patterns/state-as-resource",
    "Is this a verb on a controller that wants to be a noun resource?",
    ->(repo) do
      repo.routes.filter_map do |line, number|
        verb = line[/^\s*(post|patch|put|delete)\s+[:"']/, 1]
        controller, action = line[/to:\s*["']([\w\/]+#\w+)["']/, 1]&.split("#")
        next if controller && protocol?(controller, action)

        if verb && !line.match?(/to:\s*["'][\w\/]+#(#{CRUD.join("|")})["']/)
          Finding.new(nil, "config/routes.rb", number, "#{verb} route outside resources: #{line.strip}", line.squish)
        end
      end
    end),

  Check.new("route-restriction", "voice/dhh-refactors",
    "Is there a specific story behind restricting these actions? If not, declare the full resource.",
    ->(repo) do
      repo.routes.filter_map do |line, number|
        if line.include?("except:")
          Finding.new(nil, "config/routes.rb", number, "except: list — #{line.strip}", line.squish)
        elsif (actions = line[/only:\s*%i\[([^\]]*)\]/, 1]) && actions.split.size >= 4
          Finding.new(nil, "config/routes.rb", number, "only: #{actions.split.size} actions — #{line.strip}", line.squish)
        end
      end
    end),

  Check.new("unorganized-model", "patterns/model-concerns",
    "Can more of this model's behavior move into traits under app/models/<model>/? (Fizzy's largest, Card, is 112 lines over 23 traits.)",
    ->(repo) do
      repo.files("app/models/**/*.rb").filter_map do |path|
        next unless repo.source(path).match?(/< (ApplicationRecord|ActiveRecord::Base)\b/)

        code = repo.source(path).lines.count { it.strip.then { |l| !l.empty? && !l.start_with?("#") } }
        if code > 150
          Finding.new(nil, repo.relative(path), 1, "#{code} lines of code, #{includes_in(repo.parse(path))} traits included")
        end
      end
    end),

  Check.new("anemic-method", "voice/dhh-refactors",
    "Does this name say anything the expression doesn't? If not, inline it.",
    ->(repo) do
      files = repo.files("app/{models,controllers,helpers}/**/*.rb")
      hooks = files.flat_map { repo.source(it).scan(/^\s*def (\w+)/).flatten }.tally.select { _2 > 1 }.keys

      files.flat_map do |path|
        source = repo.source(path)
        findings = []

        each_def(repo.parse(path).statements) do |definition, visibility|
          next unless visibility == :private && definition.parameters.nil?

          statements = body_statements(definition)
          next unless statements.one? && statements.first.is_a?(Prism::CallNode)

          # A long or argument-carrying chain is an explaining name (eventable_prefix); a short bare chain may not be.
          expression = statements.first
          chain = expression.slice
          next if chain.include?("\n") || chain.start_with?("<<") || chain.match?(/[({\[]/) || chain.count(".") > 2 || expression.receiver.nil?
          next if calls_in(expression).any?(&:arguments)

          # A name also defined elsewhere is a hook another class overrides (Notifier#card), not an alias.
          name = definition.name.to_s
          next if name.end_with?("=", "?") || source.match?(/:#{Regexp.escape(name)}\b/) || hooks.include?(name)

          callers = source.scan(/(?<![\w:.@])#{Regexp.escape(name)}(?![\w?!=])/).size - 1
          if callers == 1
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "#{name} → #{chain}, one caller", name)
          end
        end

        findings
      end
    end),

  Check.new("anemic-concern", "patterns/model-concerns",
    "Does this concern carry a whole trait — associations, scopes, behavior — or just a constant or a line?",
    ->(repo) do
      repo.files("app/{models,controllers}/**/*.rb").filter_map do |path|
        source = repo.source(path)
        next unless source.include?("extend ActiveSupport::Concern")

        # Size isn't the smell: Fizzy keeps one-association traits (Card::Multistep is a lone has_many).
        # Behaviorless is: DHH dissolved Colorable, which held only constants (22abf0ba4).
        definitions = source.scan(/^\s*def\s/).size
        macros = source[/included do\n(.*?)^  end/m, 1].to_s.lines.count { !it.strip.empty? }
        if definitions + macros == 0
          Finding.new(nil, repo.relative(path), 1, "no methods or macros — constants only")
        end
      end
    end),

  Check.new("anemic-partial", "voice/dhh-refactors",
    "Does this partial earn its own file, or is it one line that belongs inline (or in a helper)?",
    ->(repo) do
      views = repo.files("app/views/**/*.erb")
      corpus = views.map { repo.source(it) }.join + repo.files("app/{controllers,helpers}/**/*.rb").map { repo.source(it) }.join

      views.filter_map do |path|
        next unless path.basename.to_s.start_with?("_")

        lines = repo.source(path).lines.count { !it.strip.empty? }
        name = path.basename.to_s.sub(/\A_/, "").sub(/\..*\z/, "")
        partial = Pathname(repo.relative(path)).dirname.relative_path_from("app/views").join(name).to_s
        renders = corpus.scan(/render[\s(]+(?:partial:\s*)?["'](?:#{Regexp.escape(partial)}|#{Regexp.escape(name)})["'][^\n]*/)
        next if renders.any? { it.include?("collection:") } # a partial per item earns its file
        references = renders.size

        if lines <= 1 && references == 1
          Finding.new(nil, repo.relative(path), 1, "#{lines} line, rendered from one place")
        end
      end
    end),

  Check.new("fat-job", "patterns/jobs-later-now",
    "Should perform be one line delegating to a model method (thing.verb), with the job only as transport?",
    ->(repo) do
      repo.files("app/jobs/**/*.rb").flat_map do |path|
        findings = []
        each_def(repo.parse(path).statements) do |definition, _|
          if definition.name == :perform && body_statements(definition).size > 2
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "perform has #{body_statements(definition).size} statements", "perform")
          end
        end
        findings
      end
    end),

  Check.new("silent-persistence", "voice/dhh-refactors",
    "Should this be save!/update!/create! so a failure raises instead of passing silently?",
    ->(repo) do
      repo.files("app/controllers/**/*.rb").flat_map do |path|
        findings = []
        each_def(repo.parse(path).statements) do |definition, _|
          body_statements(definition).each do |statement|
            if statement.is_a?(Prism::CallNode) && %i[ save update create ].include?(statement.name) && statement.receiver
              findings << Finding.new(nil, repo.relative(path), statement.location.start_line, "return value of #{statement.name} ignored", "##{definition.name} #{statement.name}")
            end
          end
        end
        findings
      end
    end),

  Check.new("state-columns", "patterns/state-as-resource",
    "Is this state with a who/when worth its own record (has_one :closure) exposed as a resource?",
    ->(repo) do
      repo.schema.scan(/create_table "(\w+)".*?\n  end/m).flat_map do |(table)|
        block = repo.schema[/create_table "#{table}".*?\n  end/m]
        columns = block.scan(/t\.\w+ "(\w+)"/).flatten
        columns.filter_map do |column|
          state = column.delete_suffix("_at")
          next unless column.end_with?("_at") && !%w[ created updated ].include?(state)

          if columns.include?("#{state}_by_id") || columns.include?(state)
            line = repo.schema.lines.index { it.include?(%(create_table "#{table}")) }.to_i + 1
            Finding.new(nil, "db/schema.rb", line, "#{table}.#{state} carries its own state + timestamp#{" + actor" if columns.include?("#{state}_by_id")}", "#{table}.#{state}")
          end
        end
      end
    end)
].freeze

def includes_in(node)
  own = node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil? ? node.arguments&.arguments.to_a.size : 0
  own + node.compact_child_nodes.sum { includes_in(it) }
end

def shape(paths)
  paths.each do |file|
    path = Pathname(file)
    lines = File.readlines(path)
    tree = Prism.parse_file(path.to_s).value
    methods = []
    each_def(tree.statements) { |definition, visibility| methods << [ definition, visibility ] }

    lengths = methods.map { |definition, _| definition.location.end_line - definition.location.start_line + 1 }
    includes = includes_in(tree)
    traits = path.sub_ext("")
    trait_files = traits.directory? ? Dir.glob(traits.join("**/*.rb")).size : 0
    comments = lines.count { it.strip.start_with?("#") }

    puts "#{file}: #{lines.size} lines, #{methods.size} methods (#{methods.count { it.last == :public }} public), " \
      "longest #{lengths.max || 0}, #{comments * 100 / [ lines.size, 1 ].max}% comments, " \
      "#{includes} includes, #{trait_files} files under #{traits.basename}/"
  end
end

def findings_in(repo, filters = [])
  findings = CHECKS.flat_map do |check|
    check.runner.(repo).compact.each { it.check = check }
  end

  findings.select! { |finding| filters.any? { finding.path.start_with?(it) } } if filters.any?

  # The same statement can appear under several resources (post :accept); number the repeats in file order.
  findings.group_by(&:id).each_value do |same|
    same.drop(1).each.with_index(2) { |finding, nth| finding.subject = "#{finding.subject} (#{nth})" }
  end

  findings
end

def report(repo, filters)
  findings = findings_in(repo, filters)

  if findings.empty?
    puts "No candidates."
  else
    findings.group_by(&:check).each do |check, group|
      puts "## #{check.name} (#{group.size}) — wiki/#{check.page}.md"
      puts "   #{check.question}"
      group.each { puts "   #{it.path}:#{it.line}  #{it.message}" }
      puts
    end
  end
end

# The same code at another git ref, checked out in a throwaway worktree.
def findings_at(repo, ref, filters)
  Dir.mktmpdir do |dir|
    worktree = File.join(dir, "tree")
    system("git", "-C", repo.toplevel.to_s, "worktree", "add", "--quiet", "--detach", worktree, ref, exception: true)
    findings_in(Repo.new(File.join(worktree, repo.root.relative_path_from(repo.toplevel))), filters)
  ensure
    system("git", "-C", repo.toplevel.to_s, "worktree", "remove", "--force", worktree, err: File::NULL)
  end
end

def since(repo, ref, filters)
  now = findings_in(repo, filters).to_h { [ it.id, it ] }
  before = findings_at(repo, ref, filters).to_h { [ it.id, it ] }

  added, fixed = now.keys - before.keys, before.keys - now.keys
  puts "Against #{ref}: #{added.size} new, #{fixed.size} fixed, #{now.size} now."
  added.each { puts "   new    #{now[it].path}:#{now[it].line}  #{now[it].message}  (wiki/#{now[it].check.page}.md)" }
  fixed.each { puts "   fixed  #{before[it].path}  #{before[it].message}" }
end

# How much fixing one finding moves the code toward Fizzy's shape.
WEIGHTS = Hash.new(1).merge("service-layer" => 3, "unorganized-model" => 3, "state-columns" => 3, "custom-action" => 2, "silent-persistence" => 2).freeze

# Commits per file over the last 90 days: the files people keep touching are where a fix pays off.
def churn(repo)
  log = IO.popen([ "git", "-C", repo.toplevel.to_s, "log", "--since=90.days.ago", "--name-only", "--format=" ], err: File::NULL, &:read)
  prefix = repo.root.relative_path_from(repo.toplevel).to_s.then { it == "." ? "" : "#{it}/" }
  log.lines.map(&:strip).grep(/\A#{Regexp.escape(prefix)}/).map { it.delete_prefix(prefix) }.tally
end

# schema.rb and routes.rb churn with every migration and route, so their findings borrow
# the churn of the model or controller they're about.
def churned_paths(finding)
  case finding.check.name
  when "state-columns"
    model = finding.subject.split(".").first.sub(/ies\z/, "y").delete_suffix("s")
    [ "app/models/#{model}.rb", "app/models/#{model.sub("_", "/")}.rb" ]
  when "custom-route"
    controller = finding.message[/to:\s*["']([\w\/]+)#/, 1]
    controller ? [ "app/controllers/#{controller}_controller.rb" ] : []
  else
    [ finding.path ]
  end
end

def rank(repo, filters, limit)
  churn = churn(repo)
  ranked = findings_in(repo, filters).map do |finding|
    size = finding.check.name == "unorganized-model" ? finding.message.to_i / 150.0 : 1
    [ finding, (WEIGHTS[finding.check.name] * (1 + churned_paths(finding).sum { churn.fetch(it, 0) }) * size).round(1) ]
  end.sort_by { -it.last }

  themes = ranked.group_by { it.first.check }.transform_values { |group| group.sum(&:last).round(1) }.sort_by { -it.last }
  puts "Themes by total score (weight × (1 + 90-day commits) × size):"
  themes.each { |check, total| puts "   #{total.to_s.rjust(7)}  #{check.name} (#{ranked.count { it.first.check == check }})" }

  if (check, = themes.first)
    puts
    puts "Next theme: #{check.name} — wiki/#{check.page}.md"
    puts "   #{check.question}"
    ranked.select { it.first.check == check }.first(limit).each do |finding, score|
      puts "   #{score.to_s.rjust(6)}  #{finding.path}:#{finding.line}  #{finding.message}"
    end
  end
end

if __FILE__ == $0
  args = ARGV.dup

  if args.delete("--shape")
    shape(args)
  else
    paths = args.index("--paths") ? args.slice!(args.index("--paths")..).drop(1) : []
    ref = args.index("--since") ? args.slice!(args.index("--since"), 2).last : nil
    limit = args.delete("--next") ? (args.find { it.match?(/\A\d+\z/) }&.then { args.delete(it).to_i } || 10) : nil

    repo = Repo.new(args.first || ".")
    filters = paths.map { repo.relative(File.expand_path(it)) }

    if ref then since(repo, ref, filters)
    elsif limit then rank(repo, filters, limit)
    else report(repo, filters)
    end
  end
end
