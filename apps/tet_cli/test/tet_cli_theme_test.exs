defmodule Tet.CLI.ThemeTest do
  use ExUnit.Case, async: true

  alias Tet.CLI.Theme

  describe "default/0" do
    test "returns a theme with name default" do
      theme = Theme.default()
      assert theme.name == "default"
    end

    test "has all required style keys" do
      theme = Theme.default()
      assert is_map(theme.heading)
      assert is_map(theme.label)
      assert is_map(theme.value)
      assert is_map(theme.error)
      assert is_map(theme.success)
      assert is_map(theme.muted)
      assert is_map(theme.accent)
    end

    test "each style spec has required fields" do
      theme = Theme.default()
      _required_keys = [:fg, :bg, :bold, :dim, :italic]

      for key <- [:heading, :label, :value, :error, :success, :muted, :accent] do
        spec = Map.get(theme, key)
        assert is_map(spec), "style #{key} is not a map"
        assert Map.has_key?(spec, :fg), "style #{key} missing :fg"
        assert Map.has_key?(spec, :bg), "style #{key} missing :bg"
        assert Map.has_key?(spec, :bold), "style #{key} missing :bold"
        assert Map.has_key?(spec, :dim), "style #{key} missing :dim"
        assert Map.has_key?(spec, :italic), "style #{key} missing :italic"
      end
    end

    test "default theme has colored heading" do
      theme = Theme.default()
      assert theme.heading.fg == :cyan
      assert theme.heading.bold == true
    end

    test "default theme has red bold error" do
      theme = Theme.default()
      assert theme.error.fg == :red
      assert theme.error.bold == true
    end
  end

  describe "plain/0" do
    test "returns a theme with name plain" do
      theme = Theme.plain()
      assert theme.name == "plain"
    end

    test "has empty reset string" do
      theme = Theme.plain()
      assert theme.reset == ""
    end

    test "all styles use default colors" do
      theme = Theme.plain()

      for key <- [:heading, :label, :value, :error, :success, :muted, :accent] do
        spec = Map.get(theme, key)
        assert spec.fg == :default
        assert spec.bg == :default
        assert spec.bold == false
        assert spec.dim == false
        assert spec.italic == false
      end
    end
  end

  describe "resolve/1" do
    test "returns default theme when force_ansi is true" do
      theme = Theme.resolve(force_ansi: true)
      assert theme.name == "default"
    end

    test "returns plain theme when force_ansi is false" do
      theme = Theme.resolve(force_ansi: false)
      assert theme.name == "plain"
    end
  end

  describe "style/3" do
    test "applies ANSI escape codes for default theme" do
      theme = Theme.default()
      result = Theme.style(theme, :heading, "Hello")
      assert result =~ "Hello"
      assert result =~ "\e["
      assert result =~ Theme.default().reset
    end

    test "plain theme emits no escape codes" do
      theme = Theme.plain()
      result = Theme.style(theme, :heading, "Hello")
      assert result == "Hello"
    end

    test "value style on default theme with default fg produces no fg code" do
      theme = Theme.default()
      # value style has fg: :default, no bold, no dim, no italic
      result = Theme.style(theme, :value, "text")
      assert result == "text"
    end
  end

  describe "convenience style functions" do
    test "heading styles text" do
      theme = Theme.default()
      assert Theme.heading(theme, "Title") =~ "Title"
    end

    test "error styles text" do
      theme = Theme.default()
      assert Theme.error(theme, "ERR") =~ "ERR"
    end

    test "success styles text" do
      theme = Theme.default()
      assert Theme.success(theme, "OK") =~ "OK"
    end

    test "muted styles text" do
      theme = Theme.default()
      assert Theme.muted(theme, "dim") =~ "dim"
    end

    test "accent styles text" do
      theme = Theme.default()
      assert Theme.accent(theme, "hi") =~ "hi"
    end

    test "label styles text" do
      theme = Theme.default()
      assert Theme.label(theme, "key") =~ "key"
    end
  end

  describe "validate/1" do
    test "validates default theme" do
      assert Theme.validate(Theme.default()) == :ok
    end

    test "validates plain theme" do
      assert Theme.validate(Theme.plain()) == :ok
    end

    test "rejects non-theme input" do
      assert Theme.validate("not a theme") == {:error, :not_a_theme}
    end

    test "rejects theme with invalid style spec" do
      theme = %{Theme.default() | heading: "not a map"}
      assert {:error, {:invalid_style_spec, :heading, "not a map"}} = Theme.validate(theme)
    end

    test "rejects theme with unsupported fg color" do
      theme = %{
        Theme.default()
        | heading: %{fg: :chartreuse, bg: :default, bold: true, dim: false, italic: false}
      }

      assert {:error, {:invalid_style_spec, :heading, _}} = Theme.validate(theme)
    end

    test "rejects theme with unsupported bg color" do
      theme = %{
        Theme.default()
        | heading: %{fg: :cyan, bg: :ultraviolet, bold: true, dim: false, italic: false}
      }

      assert {:error, {:invalid_style_spec, :heading, _}} = Theme.validate(theme)
    end

    test "accepts all standard ANSI colors in validation" do
      for color <- [
            :black,
            :red,
            :green,
            :yellow,
            :blue,
            :magenta,
            :cyan,
            :white,
            :bright_black,
            :bright_red,
            :bright_green,
            :bright_yellow,
            :bright_blue,
            :bright_magenta,
            :bright_cyan,
            :bright_white
          ] do
        theme = %{
          Theme.default()
          | heading: %{fg: color, bg: :default, bold: false, dim: false, italic: false}
        }

        assert Theme.validate(theme) == :ok
      end
    end
  end

  describe "to_map/1" do
    test "converts theme to plain map" do
      theme = Theme.default()
      map = Theme.to_map(theme)
      assert is_map(map)
      assert Map.has_key?(map, :name)
      assert Map.has_key?(map, :heading)
      assert map.name == "default"
    end
  end

  describe "theme does not alter runtime policy" do
    test "applying a theme never changes the input text content" do
      theme = Theme.default()
      text = "important policy text"

      for key <- [:heading, :label, :value, :error, :success, :muted, :accent] do
        result = Theme.style(theme, key, text)
        # Strip ANSI codes and verify content is preserved
        stripped = strip_ansi(result)
        assert stripped == text
      end
    end

    test "plain theme preserves text exactly" do
      theme = Theme.plain()
      text = "exact content"

      for key <- [:heading, :label, :value, :error, :success, :muted, :accent] do
        assert Theme.style(theme, key, text) == text
      end
    end
  end

  describe "unknown color fallback" do
    test "fg_ansi gracefully falls back for unknown color" do
      theme = %{
        Theme.default()
        | heading: %{fg: :chartreuse, bg: :default, bold: true, dim: false, italic: false}
      }

      result = Theme.style(theme, :heading, "Hello")
      # Should not raise — should fall back to default fg (code 39)
      assert result =~ "Hello"
    end
  end

  # Strip ANSI escape sequences for content verification
  defp strip_ansi(string) do
    String.replace(string, ~r/\e\[[0-9;]*m/, "")
  end
end
