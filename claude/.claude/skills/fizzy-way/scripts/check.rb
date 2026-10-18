#!/usr/bin/env ruby
# Flags the shapes 37signals corrects, each pointing at the wiki page that shows the alternative.
# Candidates, not verdicts: every check is calibrated so Fizzy itself comes out (nearly) clean.
#
#   check.rb [ROOT]                  whole app
#   check.rb [ROOT] --paths a.rb b/  only findings in these paths
#   check.rb --shape FILE...         neutral per-file readout, no judgments

require "prism"
require "pathname"

CRUD = %w[ index show new create edit update destroy ].freeze
LAYER_SUFFIXES = %w[ Service Manager Interactor Handler Operation Command Repository UseCase ].freeze
LAYER_DIRS = %w[ services interactors operations commands repositories use_cases ].freeze

Finding = Struct.new(:check, :path, :line, :message)

Check = Struct.new(:name, :page, :question, :runner)

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

  def routes
    path = root.join("config/routes.rb")
    path.exist? ? File.readlines(path) : []
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
            Finding.new(nil, repo.relative(path), klass.location.start_line, "#{name} names a role, not a domain concept")
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
          if visibility == :public && !CRUD.include?(definition.name.to_s)
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "public action ##{definition.name}")
          end
        end
        findings
      end
    end),

  Check.new("custom-route", "patterns/state-as-resource",
    "Is this a verb on a controller that wants to be a noun resource?",
    ->(repo) do
      repo.routes.each_with_index.filter_map do |line, index|
        verb = line[/^\s*(post|patch|put|delete)\s+[:"']/, 1]
        if verb && !line.match?(/to:\s*["'][\w\/]+#(#{CRUD.join("|")})["']/)
          Finding.new(nil, "config/routes.rb", index + 1, "#{verb} route outside resources: #{line.strip}")
        elsif line.match?(/^\s*member\s+do/)
          Finding.new(nil, "config/routes.rb", index + 1, "member block")
        end
      end
    end),

  Check.new("route-restriction", "voice/dhh-refactors",
    "Is there a specific story behind restricting these actions? If not, declare the full resource.",
    ->(repo) do
      repo.routes.each_with_index.filter_map do |line, index|
        if line.include?("except:")
          Finding.new(nil, "config/routes.rb", index + 1, "except: list — #{line.strip}")
        elsif (actions = line[/only:\s*%i\[([^\]]*)\]/, 1]) && actions.split.size >= 4
          Finding.new(nil, "config/routes.rb", index + 1, "only: #{actions.split.size} actions — #{line.strip}")
        end
      end
    end),

  Check.new("unorganized-model", "patterns/model-concerns",
    "Can this model's behavior be grouped into traits under app/models/<model>/?",
    ->(repo) do
      repo.files("app/models/**/*.rb").filter_map do |path|
        next unless repo.source(path).match?(/< (ApplicationRecord|ActiveRecord::Base)\b/)

        code = repo.source(path).lines.count { it.strip.then { |l| !l.empty? && !l.start_with?("#") } }
        traits = path.sub_ext("")
        if code > 150 && !traits.directory?
          Finding.new(nil, repo.relative(path), 1, "#{code} lines of code and no #{repo.relative(traits)}/ traits")
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
          next if chain.include?("\n") || chain.match?(/[({\[]/) || chain.count(".") > 2 || expression.receiver.nil?
          next if calls_in(expression).any?(&:arguments)

          # A name also defined elsewhere is a hook another class overrides (Notifier#card), not an alias.
          name = definition.name.to_s
          next if name.end_with?("=", "?") || source.match?(/:#{Regexp.escape(name)}\b/) || hooks.include?(name)

          callers = source.scan(/(?<![\w:.@])#{Regexp.escape(name)}(?![\w?!=])/).size - 1
          if callers == 1
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "#{name} → #{chain}, one caller")
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
            findings << Finding.new(nil, repo.relative(path), definition.location.start_line, "perform has #{body_statements(definition).size} statements")
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
              findings << Finding.new(nil, repo.relative(path), statement.location.start_line, "return value of #{statement.name} ignored")
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
            Finding.new(nil, "db/schema.rb", line, "#{table}.#{state} carries its own state + timestamp#{" + actor" if columns.include?("#{state}_by_id")}")
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

def report(repo, filters)
  findings = CHECKS.flat_map do |check|
    check.runner.(repo).compact.each { it.check = check }
  end

  findings.select! { |finding| filters.any? { finding.path.start_with?(it) } } if filters.any?

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

if __FILE__ == $0
  args = ARGV.dup

  if args.delete("--shape")
    shape(args)
  else
    paths = args.index("--paths") ? args.slice!(args.index("--paths")..).drop(1) : []
    repo = Repo.new(args.first || ".")
    report(repo, paths.map { repo.relative(File.expand_path(it)) })
  end
end
