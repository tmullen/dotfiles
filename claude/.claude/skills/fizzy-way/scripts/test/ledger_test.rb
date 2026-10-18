require "minitest/autorun"
require "tmpdir"
require_relative "../ledger"

class LedgerTest < Minitest::Test
  CHECK = CHECKS.find { it.name == "custom-action" }

  def setup
    @dir = Dir.mktmpdir
    @ledger = Ledger.new(Repo.new(@dir))
    @ledger.define_singleton_method(:path) { Pathname(Dir.tmpdir).join("ledger_test.yml") }
    @ledger.entries.clear
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_finding_is_new_then_fixed_then_reopened
    assert_equal [ finding.id ], @ledger.record([ finding ], on: "2026-10-01")[:new]
    assert_empty @ledger.record([ finding ], on: "2026-10-02").values.flatten

    assert_equal [ finding.id ], @ledger.record([], on: "2026-10-03")[:fixed]
    assert_equal "2026-10-03", @ledger.entries[finding.id]["fixed_on"]

    assert_equal [ finding.id ], @ledger.record([ finding ], on: "2026-10-04")[:reopened]
    assert_equal "2026-10-01", @ledger.entries[finding.id]["first_seen"]
  end

  def test_repeated_statements_get_distinct_ids
    ids = findings_in(Repo.new(File.expand_path("fixture", __dir__))).map(&:id)

    assert_includes ids, "custom-route config/routes.rb post :close"
    assert_includes ids, "custom-route config/routes.rb post :close (2)"
  end

  private
    def finding
      Finding.new(CHECK, "app/controllers/tasks_controller.rb", 62, "public action #complete", "#complete")
    end
end
