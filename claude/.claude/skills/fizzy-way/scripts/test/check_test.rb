require "minitest/autorun"
require_relative "../check"
require "fileutils"

# The checker is only trustworthy if it flags bad code and leaves Fizzy (nearly) alone.
class CheckTest < Minitest::Test
  FIXTURE = File.expand_path("fixture", __dir__)
  # Calibration runs against a fresh clone, deleted after the run.
  FIZZY = File.join(Dir.mktmpdir("fizzy-way"), "fizzy")
  CLONED = system("git", "clone", "--quiet", "https://github.com/basecamp/fizzy.git", FIZZY, err: File::NULL)
  Minitest.after_run { FileUtils.rm_rf(File.dirname(FIZZY)) }

  # Fizzy's accepted residue — each a judgment call, documented in review.md.
  FIZZY_BASELINE = [
    "route-restriction config/routes.rb",
    "anemic-method app/models/concerns/mentions.rb",
    "anemic-partial app/views/cards/triage/_columns.html.erb"
  ]

  def test_every_check_fires_on_the_fixture
    assert_equal CHECKS.map(&:name).sort, findings(FIXTURE).map { it.split.first }.uniq.sort
  end

  def test_fizzy_stays_at_its_baseline
    skip "couldn't clone Fizzy" unless CLONED

    assert_equal FIZZY_BASELINE.sort, findings(FIZZY).sort
  end

  private
    def findings(root)
      repo = Repo.new(root)
      CHECKS.flat_map { |check| check.runner.(repo).compact.map { "#{check.name} #{it.path}" } }
    end
end
