defmodule Tet.Observability.ParityMatrixTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Observability.{ParityMatrix, ParityCheck}

  describe "entries/0" do
    test "all entries have required fields" do
      required = ParityMatrix.required_keys()

      for entry <- ParityMatrix.entries() do
        for key <- required do
          assert Map.has_key?(entry, key),
                 "Entry #{entry.web_view} missing required key #{key}"
        end
      end
    end

    test "no duplicate domain+web_view combinations" do
      entries = ParityMatrix.entries()
      pairs = Enum.map(entries, &{&1.domain, &1.web_view})
      assert length(pairs) == length(Enum.uniq(pairs))
    end

    test "all statuses are valid" do
      valid = ParityMatrix.valid_statuses()

      for entry <- ParityMatrix.entries() do
        assert entry.status in valid,
               "Entry #{entry.web_view} has invalid status #{inspect(entry.status)}"
      end
    end

    test "all domains are valid" do
      valid = ParityMatrix.valid_domains()

      for entry <- ParityMatrix.entries() do
        assert entry.domain in valid,
               "Entry #{entry.web_view} has invalid domain #{inspect(entry.domain)}"
      end
    end

    test "fields is a non-empty list of atoms" do
      for entry <- ParityMatrix.entries() do
        assert is_list(entry.fields) and entry.fields != [],
               "Entry #{entry.web_view} must have non-empty fields list"

        for field <- entry.fields do
          assert is_atom(field),
                 "Entry #{entry.web_view} has non-atom field #{inspect(field)}"
        end
      end
    end

    test "data_source is a module atom" do
      for entry <- ParityMatrix.entries() do
        assert is_atom(entry.data_source),
               "Entry #{entry.web_view} data_source must be a module atom"
      end
    end

    test "cli_command and web_view are non-empty strings" do
      for entry <- ParityMatrix.entries() do
        assert is_binary(entry.cli_command) and entry.cli_command != ""
        assert is_binary(entry.web_view) and entry.web_view != ""
      end
    end

    test "returns at least 12 entries per the parity spec" do
      assert length(ParityMatrix.entries()) >= 12
    end

    test "implemented commands match real CLI syntax" do
      implemented = ParityMatrix.entries() |> Enum.filter(&(&1.status == :implemented))
      commands = Enum.map(implemented, & &1.cli_command)

      assert "tet sessions" in commands
      assert "tet session show <id>" in commands
      assert "tet doctor" in commands
    end
  end

  describe "coverage/0" do
    test "returns accurate counts" do
      %{implemented: implemented, planned: planned, total: total} = ParityMatrix.coverage()

      entries = ParityMatrix.entries()
      assert total == length(entries)
      assert implemented == Enum.count(entries, &(&1.status == :implemented))
      assert planned == Enum.count(entries, &(&1.status == :planned))
      assert implemented + planned <= total
    end

    test "implemented count matches known entries" do
      # SessionLive.Index, SessionLive.Show, TelemetryLive.Dashboard
      %{implemented: implemented} = ParityMatrix.coverage()
      assert implemented == 3
    end

    test "total equals implemented plus planned (no :not_needed entries yet)" do
      %{implemented: implemented, planned: planned, total: total} = ParityMatrix.coverage()
      assert implemented + planned == total
    end
  end

  describe "gaps/0" do
    test "only returns non-implemented entries" do
      for entry <- ParityMatrix.gaps() do
        assert entry.status != :implemented,
               "gaps/0 should not include implemented entry #{entry.web_view}"
      end
    end

    test "gap count matches total minus implemented" do
      %{implemented: implemented, total: total} = ParityMatrix.coverage()
      assert length(ParityMatrix.gaps()) == total - implemented
    end

    test "all gap entries are valid parity entries" do
      required = ParityMatrix.required_keys()

      for entry <- ParityMatrix.gaps() do
        for key <- required do
          assert Map.has_key?(entry, key)
        end
      end
    end
  end

  describe "for_domain/1" do
    test "filters correctly for each domain" do
      for domain <- ParityMatrix.valid_domains() do
        filtered = ParityMatrix.for_domain(domain)

        for entry <- filtered do
          assert entry.domain == domain,
                 "for_domain(#{domain}) returned entry with domain #{entry.domain}"
        end
      end
    end

    test "session domain returns index and show views" do
      sessions = ParityMatrix.for_domain(:session)
      assert length(sessions) == 2
      web_views = Enum.map(sessions, & &1.web_view)
      assert "SessionLive.Index" in web_views
      assert "SessionLive.Show" in web_views
    end

    test "error_log domain returns index and show views" do
      errors = ParityMatrix.for_domain(:error_log)
      assert length(errors) == 2
      web_views = Enum.map(errors, & &1.web_view)
      assert "ErrorLogLive.Index" in web_views
      assert "ErrorLogLive.Show" in web_views
    end

    test "all entries are covered by at least one domain" do
      all_from_domains =
        ParityMatrix.valid_domains()
        |> Enum.flat_map(&ParityMatrix.for_domain/1)

      assert length(all_from_domains) == length(ParityMatrix.entries())
    end

    test "each returned entry is a member of entries/0" do
      all = ParityMatrix.entries()

      for domain <- ParityMatrix.valid_domains() do
        for entry <- ParityMatrix.for_domain(domain) do
          assert entry in all
        end
      end
    end
  end

  describe "verify/1" do
    test "annotates entries with availability boolean" do
      results = ParityMatrix.verify(Tet.Store)

      for result <- results do
        assert Map.has_key?(result, :available)
        assert is_boolean(result.available)
      end
    end

    test "handles missing store module gracefully" do
      results = ParityMatrix.verify(This.Module.Does.Not.Exist)

      store_entries = Enum.filter(results, &(&1.data_source == Tet.Store))

      for entry <- store_entries do
        refute entry.available,
               "Store entry #{entry.web_view} should be unavailable for missing module"
      end
    end

    test "preserves all original entry fields" do
      required = ParityMatrix.required_keys()
      results = ParityMatrix.verify(Tet.Store)

      for result <- results do
        for key <- required do
          assert Map.has_key?(result, key)
        end
      end
    end

    test "returns same number of entries as entries/0" do
      results = ParityMatrix.verify(Tet.Store)
      assert length(results) == length(ParityMatrix.entries())
    end

    test "Tet.Store behaviour module itself is loadable" do
      # Tet.Store is a behaviour defined in tet_core, so it should be loadable
      results = ParityMatrix.verify(Tet.Store)
      store_entries = Enum.filter(results, &(&1.data_source == Tet.Store))

      for entry <- store_entries do
        assert entry.available
      end
    end
  end

  describe "ParityCheck.run/1" do
    test "returns pass/fail/skip groups" do
      result = ParityCheck.run(Tet.Store)
      assert Map.has_key?(result, :pass)
      assert Map.has_key?(result, :fail)
      assert Map.has_key?(result, :skip)
    end

    test "all results have entry, result, and available keys" do
      %{pass: pass, fail: fail, skip: skip} = ParityCheck.run(Tet.Store)

      for result <- pass ++ fail ++ skip do
        assert Map.has_key?(result, :entry)
        assert Map.has_key?(result, :result)
        assert Map.has_key?(result, :available)
      end
    end

    test "pass entries have :pass result" do
      %{pass: pass} = ParityCheck.run(Tet.Store)

      for result <- pass do
        assert result.result == :pass
      end
    end

    test "fail entries have :fail result" do
      %{fail: fail} = ParityCheck.run(Tet.Store)

      for result <- fail do
        assert result.result == :fail
      end
    end

    test "total results match entries count" do
      %{pass: pass, fail: fail, skip: skip} = ParityCheck.run(Tet.Store)
      assert length(pass) + length(fail) + length(skip) == length(ParityMatrix.entries())
    end
  end

  describe "ParityCheck.report/1" do
    test "returns a non-empty string" do
      report =
        Tet.Store
        |> ParityCheck.run()
        |> ParityCheck.report()

      assert is_binary(report)
      assert report != ""
    end

    test "contains header and coverage line" do
      report =
        Tet.Store
        |> ParityCheck.run()
        |> ParityCheck.report()

      assert report =~ "Observability Parity Report"
      assert report =~ "Coverage:"
    end

    test "contains section markers" do
      report =
        Tet.Store
        |> ParityCheck.run()
        |> ParityCheck.report()

      assert report =~ "Passing"
      assert report =~ "Failing"
      assert report =~ "Skipped"
    end
  end
end
